const std = @import("std");

pub const Edge = struct {
    a: u32,
    b: u32,

    pub fn init(a: usize, b: usize) Edge {
        return if (a < b) .{ .a = @intCast(a), .b = @intCast(b) } else .{ .a = @intCast(b), .b = @intCast(a) };
    }
};

const Triangle = struct { a: u32, b: u32, c: u32 };

/// Compact Bowyer-Watson triangulation. Returns the unique undirected edges.
/// Coordinates are flattened as [x0,y0,x1,y1,...].
pub fn delaunay2d(allocator: std.mem.Allocator, coords: []const f32) ![]Edge {
    if (coords.len % 2 != 0) return error.InvalidCoordinates;
    const n = coords.len / 2;
    if (n < 2) return allocator.alloc(Edge, 0);
    if (n == 2) {
        const out = try allocator.alloc(Edge, 1);
        out[0] = Edge.init(0, 1);
        return out;
    }

    var points: std.ArrayList([2]f64) = .empty;
    defer points.deinit(allocator);
    try points.ensureTotalCapacity(allocator, n + 3);
    var min_x: f64 = coords[0];
    var max_x = min_x;
    var min_y: f64 = coords[1];
    var max_y = min_y;
    for (0..n) |i| {
        const p: [2]f64 = .{ coords[i * 2], coords[i * 2 + 1] };
        try points.append(allocator, p);
        min_x = @min(min_x, p[0]);
        max_x = @max(max_x, p[0]);
        min_y = @min(min_y, p[1]);
        max_y = @max(max_y, p[1]);
    }
    const d = @max(max_x - min_x, max_y - min_y) + 1.0;
    const mx = (min_x + max_x) * 0.5;
    const my = (min_y + max_y) * 0.5;
    try points.appendSlice(allocator, &.{ .{ mx - 20 * d, my - d }, .{ mx, my + 20 * d }, .{ mx + 20 * d, my - d } });

    var tris: std.ArrayList(Triangle) = .empty;
    defer tris.deinit(allocator);
    try tris.append(allocator, .{ .a = @intCast(n), .b = @intCast(n + 1), .c = @intCast(n + 2) });

    for (0..n) |pi| {
        var boundary: std.ArrayList(Edge) = .empty;
        defer boundary.deinit(allocator);
        var write: usize = 0;
        for (tris.items) |t| {
            if (inCircumcircle(points.items[pi], points.items[t.a], points.items[t.b], points.items[t.c])) {
                toggleEdge(allocator, &boundary, Edge.init(t.a, t.b)) catch return error.OutOfMemory;
                toggleEdge(allocator, &boundary, Edge.init(t.b, t.c)) catch return error.OutOfMemory;
                toggleEdge(allocator, &boundary, Edge.init(t.c, t.a)) catch return error.OutOfMemory;
            } else {
                tris.items[write] = t;
                write += 1;
            }
        }
        tris.items.len = write;
        for (boundary.items) |e| try tris.append(allocator, .{ .a = e.a, .b = e.b, .c = @intCast(pi) });
    }

    var edges: std.ArrayList(Edge) = .empty;
    errdefer edges.deinit(allocator);
    for (tris.items) |t| {
        if (t.a >= n or t.b >= n or t.c >= n) continue;
        try addUnique(allocator, &edges, Edge.init(t.a, t.b));
        try addUnique(allocator, &edges, Edge.init(t.b, t.c));
        try addUnique(allocator, &edges, Edge.init(t.c, t.a));
    }
    return edges.toOwnedSlice(allocator);
}

fn toggleEdge(allocator: std.mem.Allocator, edges: *std.ArrayList(Edge), edge: Edge) !void {
    for (edges.items, 0..) |e, i| if (e.a == edge.a and e.b == edge.b) {
        _ = edges.swapRemove(i);
        return;
    };
    try edges.append(allocator, edge);
}

fn addUnique(allocator: std.mem.Allocator, edges: *std.ArrayList(Edge), edge: Edge) !void {
    for (edges.items) |e| if (e.a == edge.a and e.b == edge.b) return;
    try edges.append(allocator, edge);
}

fn inCircumcircle(p: [2]f64, a: [2]f64, b: [2]f64, c: [2]f64) bool {
    const ax = a[0] - p[0];
    const ay = a[1] - p[1];
    const bx = b[0] - p[0];
    const by = b[1] - p[1];
    const cx = c[0] - p[0];
    const cy = c[1] - p[1];
    const det = (ax * ax + ay * ay) * (bx * cy - cx * by) -
        (bx * bx + by * by) * (ax * cy - cx * ay) +
        (cx * cx + cy * cy) * (ax * by - bx * ay);
    const orientation = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
    return if (orientation > 0) det > 1e-12 else det < -1e-12;
}

test "square triangulates into five edges" {
    const coords = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 1 };
    const edges = try delaunay2d(std.testing.allocator, &coords);
    defer std.testing.allocator.free(edges);
    try std.testing.expectEqual(@as(usize, 5), edges.len);
}
