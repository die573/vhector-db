const std = @import("std");
const Store = @import("store.zig").Store;
const ReadGuard = @import("store.zig").ReadGuard;
const Aof = @import("aof.zig").Aof;
const ReplayStats = @import("aof.zig").ReplayStats;
const ClusterConfig = @import("cluster.zig").Config;

pub const Config = struct {
    dim: usize,
    graph_neighbors: usize = 8,
    rebuild_interval_ms: u64 = 100,
    sync_on_write: bool = false,
    clustering: ClusterConfig = .{},
};

/// Durable database facade. Mutations are logged before they become visible;
/// a worker periodically turns dirty mutable state into a read snapshot.
pub const Database = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    store: Store,
    log: Aof,
    replay_stats: ReplayStats,
    dirty: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    worker: ?std.Thread = null,
    write_lock: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config, path: []const u8) !Database {
        var store = try Store.init(allocator, config.dim, config.graph_neighbors, config.clustering);
        errdefer store.deinit();
        var log = try Aof.open(allocator, io, path);
        errdefer log.close();
        const replay_stats = try log.replay(&store, nowMs(io));
        _ = try store.rebuild(nowMs(io));
        return .{ .allocator = allocator, .io = io, .config = config, .store = store, .log = log, .replay_stats = replay_stats };
    }

    pub fn deinit(self: *Database) void {
        self.stop();
        self.log.close();
        self.store.deinit();
        self.* = undefined;
    }

    pub fn start(self: *Database) !void {
        if (self.worker != null) return;
        self.stopping.store(false, .release);
        self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn stop(self: *Database) void {
        const worker = self.worker orelse return;
        self.stopping.store(true, .release);
        worker.join();
        self.worker = null;
    }

    pub fn put(self: *Database, id: u64, coords: []const f32, ttl_ms: u64) !void {
        self.lockWrites();
        defer self.write_lock.unlock();
        const now = nowMs(self.io);
        const expires = if (ttl_ms == 0) 0 else now +| ttl_ms;
        try self.log.appendPut(id, coords, expires);
        if (self.config.sync_on_write) try self.log.sync();
        try self.store.putExpiresAt(id, coords, expires);
        self.dirty.store(true, .release);
    }

    pub fn remove(self: *Database, id: u64) !bool {
        self.lockWrites();
        defer self.write_lock.unlock();
        try self.log.appendRemove(id);
        if (self.config.sync_on_write) try self.log.sync();
        const existed = self.store.remove(id);
        if (existed) self.dirty.store(true, .release);
        return existed;
    }

    pub fn rebuild(self: *Database) !u64 {
        const next_generation = try self.store.rebuild(nowMs(self.io));
        self.dirty.store(false, .release);
        return next_generation;
    }

    pub fn acquire(self: *Database) ?ReadGuard {
        return self.store.acquire();
    }

    pub fn generation(self: *const Database) u64 {
        return self.store.generation;
    }
    pub fn pendingRebuild(self: *const Database) bool {
        return self.dirty.load(.acquire);
    }

    fn lockWrites(self: *Database) void {
        while (!self.write_lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn workerMain(self: *Database) void {
        const interval: i64 = @intCast(self.config.rebuild_interval_ms);
        while (!self.stopping.load(.acquire)) {
            if (self.dirty.swap(false, .acq_rel)) {
                _ = self.store.rebuild(nowMs(self.io)) catch |err| {
                    self.dirty.store(true, .release);
                    std.log.err("background rebuild failed: {s}", .{@errorName(err)});
                };
            }
            std.Io.sleep(self.io, .fromMilliseconds(interval), .awake) catch break;
        }
        if (self.dirty.swap(false, .acq_rel)) _ = self.store.rebuild(nowMs(self.io)) catch {};
        self.store.collect();
    }
};

pub fn nowMs(io: std.Io) u64 {
    const value = std.Io.Clock.real.now(io).toMilliseconds();
    return @intCast(@max(value, 0));
}
