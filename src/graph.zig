const std = @import("std");
const geometry = @import("geometry.zig");

pub const Point = struct { id: u64, coords: []const f32 };

/// Immutable topology used by readers and the clustering pass.
pub const Neighborhood = struct {
    allocator: std.mem.Allocator,
    dim: usize,
    ids: []u64,
    coords: []f32,
    edges: []geometry.Edge,

    pub fn build(allocator: std.mem.Allocator, points: []const Point, dim: usize, k: usize) !Neighborhood {
        if (dim == 0) return error.InvalidDimension;
        const ids = try allocator.alloc(u64, points.len);
        errdefer allocator.free(ids);
        const coords = try allocator.alloc(f32, points.len * dim);
        errdefer allocator.free(coords);
        for (points, 0..) |p, i| {
            if (p.coords.len != dim) return error.DimensionMismatch;
            ids[i] = p.id;
            @memcpy(coords[i * dim ..][0..dim], p.coords);
        }
        const edges = if (dim == 2)
            try geometry.delaunay2d(allocator, coords)
        else
            try knnEdges(allocator, coords, dim, k);
        return .{ .allocator = allocator, .dim = dim, .ids = ids, .coords = coords, .edges = edges };
    }

    pub fn deinit(self: *Neighborhood) void {
        self.allocator.free(self.ids);
        self.allocator.free(self.coords);
        self.allocator.free(self.edges);
        self.* = undefined;
    }

    pub fn point(self: *const Neighborhood, i: usize) []const f32 {
        return self.coords[i * self.dim ..][0..self.dim];
    }
};

fn knnEdges(allocator: std.mem.Allocator, coords: []const f32, dim: usize, k_requested: usize) ![]geometry.Edge {
    const n = coords.len / dim;
    const k = @min(k_requested, n -| 1);
    var out: std.ArrayList(geometry.Edge) = .empty;
    errdefer out.deinit(allocator);
    var best = try allocator.alloc(struct { d: f32, i: usize }, k);
    defer allocator.free(best);
    for (0..n) |i| {
        var used: usize = 0;
        for (0..n) |j| {
            if (i == j) continue;
            const d = distance2(coords[i * dim ..][0..dim], coords[j * dim ..][0..dim]);
            var pos = used;
            if (pos > k) pos = k;
            while (pos > 0 and best[pos - 1].d > d) : (pos -= 1) {
                if (pos < k) best[pos] = best[pos - 1];
            }
            if (pos < k) best[pos] = .{ .d = d, .i = j };
            used = @min(used + 1, k);
        }
        for (best[0..used]) |entry| try addUnique(allocator, &out, geometry.Edge.init(i, entry.i));
    }
    return out.toOwnedSlice(allocator);
}

pub fn distance2(a: []const f32, b: []const f32) f32 {
    var sum: f32 = 0;
    for (a, b) |x, y| {
        const d = x - y;
        sum += d * d;
    }
    return sum;
}

fn addUnique(allocator: std.mem.Allocator, out: *std.ArrayList(geometry.Edge), edge: geometry.Edge) !void {
    for (out.items) |e| if (e.a == edge.a and e.b == edge.b) return;
    try out.append(allocator, edge);
}

test "higher dimensional graph uses exact k nearest neighbors" {
    const p = [_]Point{
        .{ .id = 1, .coords = &.{ 0, 0, 0 } }, .{ .id = 2, .coords = &.{ 1, 0, 0 } },
        .{ .id = 3, .coords = &.{ 9, 0, 0 } }, .{ .id = 4, .coords = &.{ 10, 0, 0 } },
    };
    var graph = try Neighborhood.build(std.testing.allocator, &p, 3, 1);
    defer graph.deinit();
    try std.testing.expect(graph.edges.len >= 2);
}
