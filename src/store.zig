const std = @import("std");
const graph_mod = @import("graph.zig");
const cluster_mod = @import("cluster.zig");

const Record = struct {
    id: u64,
    coords: []f32,
    expires_at_ms: u64,
    live: bool = true,
};

pub const Match = struct { id: u64, distance_squared: f32 };

/// An immutable, queryable generation of the database.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    generation: u64,
    topology: graph_mod.Neighborhood,
    clusters: []u32,

    fn deinit(self: *Snapshot) void {
        self.topology.deinit();
        self.allocator.free(self.clusters);
        self.allocator.destroy(self);
    }

    pub fn count(self: *const Snapshot) usize {
        return self.topology.ids.len;
    }

    pub fn find(self: *const Snapshot, id: u64) ?[]const f32 {
        for (self.topology.ids, 0..) |candidate, i| if (candidate == id) return self.topology.point(i);
        return null;
    }

    /// Exact scan for now. A KD-tree query layer can replace this without
    /// changing snapshot publication or the public store API.
    pub fn nearest(self: *const Snapshot, query: []const f32, out: []Match) ![]Match {
        if (query.len != self.topology.dim) return error.DimensionMismatch;
        var used: usize = 0;
        for (self.topology.ids, 0..) |id, i| {
            const candidate = Match{ .id = id, .distance_squared = graph_mod.distance2(query, self.topology.point(i)) };
            var pos = used;
            while (pos > 0 and out[pos - 1].distance_squared > candidate.distance_squared) : (pos -= 1) {
                if (pos < out.len) out[pos] = out[pos - 1];
            }
            if (pos < out.len) out[pos] = candidate;
            used = @min(used + 1, out.len);
        }
        return out[0..used];
    }

    pub fn within(self: *const Snapshot, query: []const f32, radius: f32, out: []Match) ![]Match {
        if (query.len != self.topology.dim) return error.DimensionMismatch;
        const limit = radius * radius;
        var used: usize = 0;
        for (self.topology.ids, 0..) |id, i| {
            const distance = graph_mod.distance2(query, self.topology.point(i));
            if (distance <= limit and used < out.len) {
                out[used] = .{ .id = id, .distance_squared = distance };
                used += 1;
            }
        }
        std.mem.sort(Match, out[0..used], {}, struct {
            fn lessThan(_: void, a: Match, b: Match) bool {
                return a.distance_squared < b.distance_squared;
            }
        }.lessThan);
        return out[0..used];
    }
};

/// Pins the global read epoch. Guards must be released promptly.
pub const ReadGuard = struct {
    owner: *Store,
    snapshot: *const Snapshot,

    pub fn release(self: *ReadGuard) void {
        _ = self.owner.readers.fetchSub(1, .release);
        self.* = undefined;
    }
};

/// Mutable ingest state plus an atomically published immutable read generation.
/// Reclamation is epoch-based: retired generations are freed only at a global
/// quiescent point, when no ReadGuard exists.
pub const Store = struct {
    allocator: std.mem.Allocator,
    dim: usize,
    k: usize,
    cluster_config: cluster_mod.Config,
    mutex: std.atomic.Mutex = .unlocked,
    records: std.ArrayList(Record) = .empty,
    by_id: std.AutoHashMap(u64, usize),
    current: std.atomic.Value(?*Snapshot) = .init(null),
    readers: std.atomic.Value(usize) = .init(0),
    retired: std.ArrayList(*Snapshot) = .empty,
    generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, dim: usize, k: usize, cluster_config: cluster_mod.Config) !Store {
        if (dim == 0) return error.InvalidDimension;
        return .{ .allocator = allocator, .dim = dim, .k = k, .cluster_config = cluster_config, .by_id = .init(allocator) };
    }

    pub fn deinit(self: *Store) void {
        std.debug.assert(self.readers.load(.acquire) == 0);
        if (self.current.load(.acquire)) |snapshot| snapshot.deinit();
        for (self.retired.items) |snapshot| snapshot.deinit();
        for (self.records.items) |record| self.allocator.free(record.coords);
        self.retired.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.by_id.deinit();
        self.* = undefined;
    }

    pub fn put(self: *Store, id: u64, coords: []const f32, ttl_ms: u64, now_ms: u64) !void {
        const expires = if (ttl_ms == 0) 0 else now_ms +| ttl_ms;
        return self.putExpiresAt(id, coords, expires);
    }

    pub fn putExpiresAt(self: *Store, id: u64, coords: []const f32, expires_at_ms: u64) !void {
        if (coords.len != self.dim) return error.DimensionMismatch;
        self.lock();
        defer self.mutex.unlock();
        const owned = try self.allocator.dupe(f32, coords);
        errdefer self.allocator.free(owned);
        if (self.by_id.get(id)) |index| {
            self.allocator.free(self.records.items[index].coords);
            self.records.items[index].coords = owned;
            self.records.items[index].expires_at_ms = expires_at_ms;
            self.records.items[index].live = true;
        } else {
            const index = self.records.items.len;
            try self.records.append(self.allocator, .{ .id = id, .coords = owned, .expires_at_ms = expires_at_ms });
            errdefer _ = self.records.pop();
            try self.by_id.put(id, index);
        }
    }

    pub fn remove(self: *Store, id: u64) bool {
        self.lock();
        defer self.mutex.unlock();
        const index = self.by_id.get(id) orelse return false;
        self.records.items[index].live = false;
        _ = self.by_id.remove(id);
        return true;
    }

    /// Builds outside the published read path, then swaps generations atomically.
    pub fn rebuild(self: *Store, now_ms: u64) !u64 {
        self.lock();
        defer self.mutex.unlock();
        var points: std.ArrayList(graph_mod.Point) = .empty;
        defer points.deinit(self.allocator);
        for (self.records.items) |*record| {
            if (!record.live) continue;
            if (record.expires_at_ms != 0 and record.expires_at_ms <= now_ms) {
                record.live = false;
                _ = self.by_id.remove(record.id);
                continue;
            }
            try points.append(self.allocator, .{ .id = record.id, .coords = record.coords });
        }

        const snapshot = try self.allocator.create(Snapshot);
        errdefer self.allocator.destroy(snapshot);
        var topology = try graph_mod.Neighborhood.build(self.allocator, points.items, self.dim, self.k);
        errdefer topology.deinit();
        var optimizer = try cluster_mod.Clusterer.init(self.allocator, &topology, self.cluster_config);
        defer optimizer.deinit();
        const assignment = optimizer.run();
        const clusters = try self.allocator.dupe(u32, assignment);
        self.generation += 1;
        snapshot.* = .{ .allocator = self.allocator, .generation = self.generation, .topology = topology, .clusters = clusters };
        if (self.current.swap(snapshot, .acq_rel)) |old| try self.retired.append(self.allocator, old);
        self.collectUnlocked();
        return self.generation;
    }

    pub fn acquire(self: *Store) ?ReadGuard {
        _ = self.readers.fetchAdd(1, .acquire);
        const snapshot = self.current.load(.acquire) orelse {
            _ = self.readers.fetchSub(1, .release);
            return null;
        };
        return .{ .owner = self, .snapshot = snapshot };
    }

    /// Attempts epoch reclamation. It is safe to call after any rebuild or read burst.
    pub fn collect(self: *Store) void {
        self.lock();
        defer self.mutex.unlock();
        self.collectUnlocked();
    }

    fn collectUnlocked(self: *Store) void {
        if (self.readers.load(.acquire) != 0) return;
        for (self.retired.items) |snapshot| snapshot.deinit();
        self.retired.clearRetainingCapacity();
    }

    fn lock(self: *Store) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

test "TTL filtering, nearest query, and epoch retirement" {
    var store = try Store.init(std.testing.allocator, 2, 4, .{ .merge_cost = 0.2 });
    defer store.deinit();
    try store.put(1, &.{ 0, 0 }, 0, 100);
    try store.put(2, &.{ 1, 0 }, 50, 100);
    try store.put(3, &.{ 10, 10 }, 0, 100);
    _ = try store.rebuild(100);

    var old = store.acquire().?;
    try std.testing.expectEqual(@as(usize, 3), old.snapshot.count());
    var matches: [2]Match = undefined;
    const nearest = try old.snapshot.nearest(&.{ 0.2, 0 }, &matches);
    try std.testing.expectEqual(@as(u64, 1), nearest[0].id);

    _ = try store.rebuild(151);
    try std.testing.expectEqual(@as(usize, 1), store.retired.items.len);
    old.release();
    store.collect();
    try std.testing.expectEqual(@as(usize, 0), store.retired.items.len);
    var fresh = store.acquire().?;
    defer fresh.release();
    try std.testing.expectEqual(@as(usize, 2), fresh.snapshot.count());
}
