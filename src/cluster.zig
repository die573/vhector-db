const std = @import("std");
const graph_mod = @import("graph.zig");

pub const Config = struct {
    merge_cost: f64 = 1.0,
    noise: f64 = 0.0,
    max_sweeps: usize = 32,
    seed: u64 = 0x5648_4543_544f_52,
};

pub const Clusterer = struct {
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Neighborhood,
    config: Config,
    parent: []u32,
    count: []u32,
    means: []f64,
    rng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, graph: *const graph_mod.Neighborhood, config: Config) !Clusterer {
        const n = graph.ids.len;
        const parent = try allocator.alloc(u32, n);
        errdefer allocator.free(parent);
        const count = try allocator.alloc(u32, n);
        errdefer allocator.free(count);
        const means = try allocator.alloc(f64, n * graph.dim);
        errdefer allocator.free(means);
        for (0..n) |i| {
            parent[i] = @intCast(i);
            count[i] = 1;
            for (0..graph.dim) |d| means[i * graph.dim + d] = graph.coords[i * graph.dim + d];
        }
        return .{ .allocator = allocator, .graph = graph, .config = config, .parent = parent, .count = count, .means = means, .rng = .init(config.seed) };
    }

    pub fn deinit(self: *Clusterer) void {
        self.allocator.free(self.parent);
        self.allocator.free(self.count);
        self.allocator.free(self.means);
        self.* = undefined;
    }

    /// Repeated randomized sweeps over spatial edges using Ward's merge cost.
    pub fn run(self: *Clusterer) []const u32 {
        var sweep: usize = 0;
        while (sweep < self.config.max_sweeps) : (sweep += 1) {
            var merged = false;
            const start = if (self.graph.edges.len == 0) 0 else self.rng.random().uintLessThan(usize, self.graph.edges.len);
            for (0..self.graph.edges.len) |offset| {
                const e = self.graph.edges[(start + offset) % self.graph.edges.len];
                const a = self.root(e.a);
                const b = self.root(e.b);
                if (a == b) continue;
                const jitter = (self.rng.random().float(f64) * 2.0 - 1.0) * self.config.noise;
                if (self.wardCost(a, b) + jitter <= self.config.merge_cost) {
                    self.merge(a, b);
                    merged = true;
                }
            }
            if (!merged) break;
        }
        for (self.parent, 0..) |_, i| self.parent[i] = self.root(@intCast(i));
        return self.parent;
    }

    fn root(self: *Clusterer, value: u32) u32 {
        var r = value;
        while (self.parent[r] != r) r = self.parent[r];
        var x = value;
        while (self.parent[x] != x) {
            const next = self.parent[x];
            self.parent[x] = r;
            x = next;
        }
        return r;
    }

    fn wardCost(self: *const Clusterer, a: u32, b: u32) f64 {
        var dist: f64 = 0;
        for (0..self.graph.dim) |d| {
            const x = self.means[@as(usize, a) * self.graph.dim + d] - self.means[@as(usize, b) * self.graph.dim + d];
            dist += x * x;
        }
        const na: f64 = @floatFromInt(self.count[a]);
        const nb: f64 = @floatFromInt(self.count[b]);
        return na * nb / (na + nb) * dist;
    }

    fn merge(self: *Clusterer, a: u32, b: u32) void {
        var keep = a;
        var drop = b;
        if (self.count[keep] < self.count[drop]) {
            keep = b;
            drop = a;
        }
        const nk: f64 = @floatFromInt(self.count[keep]);
        const nd: f64 = @floatFromInt(self.count[drop]);
        for (0..self.graph.dim) |d| {
            const ki = @as(usize, keep) * self.graph.dim + d;
            const di = @as(usize, drop) * self.graph.dim + d;
            self.means[ki] = (self.means[ki] * nk + self.means[di] * nd) / (nk + nd);
        }
        self.count[keep] += self.count[drop];
        self.count[drop] = 0;
        self.parent[drop] = keep;
    }
};

test "ward clustering preserves two separated groups" {
    const Point = graph_mod.Point;
    const points = [_]Point{
        .{ .id = 1, .coords = &.{ 0, 0 } },   .{ .id = 2, .coords = &.{ 0.1, 0 } },
        .{ .id = 3, .coords = &.{ 10, 10 } }, .{ .id = 4, .coords = &.{ 10.1, 10 } },
    };
    var graph = try graph_mod.Neighborhood.build(std.testing.allocator, &points, 2, 4);
    defer graph.deinit();
    var c = try Clusterer.init(std.testing.allocator, &graph, .{ .merge_cost = 0.1 });
    defer c.deinit();
    const assignment = c.run();
    try std.testing.expectEqual(assignment[0], assignment[1]);
    try std.testing.expectEqual(assignment[2], assignment[3]);
    try std.testing.expect(assignment[0] != assignment[2]);
}
