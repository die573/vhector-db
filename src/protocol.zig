const std = @import("std");
const Database = @import("database.zig").Database;
const Match = @import("store.zig").Match;
const demo = @import("demo.zig");

/// Executes one VRESP command. Returns false for QUIT.
pub fn execute(allocator: std.mem.Allocator, db: *Database, line: []const u8, writer: *std.Io.Writer) !bool {
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r\n");
    const command = tokens.next() orelse return true;
    if (eq(command, "PING")) {
        try writer.writeAll("+PONG\r\n");
        return true;
    }
    if (eq(command, "QUIT")) {
        try writer.writeAll("+BYE\r\n");
        return false;
    }
    if (eq(command, "PUT")) return put(allocator, db, &tokens, writer);
    if (eq(command, "GET")) return get(db, &tokens, writer);
    if (eq(command, "DEL")) return remove(db, &tokens, writer);
    if (eq(command, "KNN")) return knn(allocator, db, &tokens, writer);
    if (eq(command, "RANGE")) return range(allocator, db, &tokens, writer);
    if (eq(command, "CLUSTERS")) return clusters(db, writer);
    if (eq(command, "REBUILD")) {
        const gen = try db.rebuild();
        try writer.print(":{d}\r\n", .{gen});
        return true;
    }
    if (eq(command, "STATS")) return stats(db, writer);
    if (eq(command, "DEMO")) return runDemo(allocator, db, &tokens, writer);
    return fail(writer, "unknown command");
}

fn runDemo(allocator: std.mem.Allocator, db: *Database, tokens: anytype, writer: *std.Io.Writer) !bool {
    const first = tokens.next() orelse return fail(writer, "DEMO requires [SCENARIO] TERMINAL, PREVIEW, or VIDEO");
    var scenario: demo.Scenario = .gaussian;
    const mode_text = if (isDemoMode(first)) first else blk: {
        scenario = parseScenario(first) orelse return fail(writer, "unknown demo scenario");
        break :blk tokens.next() orelse return fail(writer, "missing demo mode");
    };
    const seconds = if (tokens.next()) |value| parseInt(u8, value) catch return fail(writer, "invalid duration") else 8;
    if (seconds == 0 or seconds > 30) return fail(writer, "duration must be 1..30 seconds");
    if (eq(mode_text, "TERMINAL")) {
        if (tokens.next() != null) return fail(writer, "too many arguments");
        try demo.runTerminal(allocator, db.io, writer, .{ .scenario = scenario, .seconds = seconds, .width = 80, .height = 26 });
        return true;
    }
    if (eq(mode_text, "VIDEO")) {
        const output = tokens.next() orelse "vhector-demo.mp4";
        if (tokens.next() != null) return fail(writer, "too many arguments");
        if (std.mem.indexOfAny(u8, output, "\\/:") != null or !std.mem.endsWith(u8, output, ".mp4")) return fail(writer, "output must be a local .mp4 filename");
        try writer.writeAll("+DEMO RECORDING\r\n");
        try writer.flush();
        demo.runVideo(allocator, db.io, .{ .scenario = scenario, .seconds = seconds, .output = output }) catch |err| return failError(writer, err);
        try writer.print("+DEMO WROTE {s}\r\n", .{output});
        return true;
    }
    if (eq(mode_text, "PREVIEW")) {
        if (tokens.next() != null) return fail(writer, "too many arguments");
        try writer.writeAll("+DEMO PREVIEWING\r\n");
        try writer.flush();
        demo.runPreview(allocator, db.io, .{ .scenario = scenario, .seconds = seconds }) catch |err| return failError(writer, err);
        try writer.writeAll("+DEMO DONE\r\n");
        return true;
    }
    return fail(writer, "DEMO mode must be TERMINAL, PREVIEW, or VIDEO");
}

fn isDemoMode(value: []const u8) bool {
    return eq(value, "TERMINAL") or eq(value, "PREVIEW") or eq(value, "VIDEO");
}
fn parseScenario(value: []const u8) ?demo.Scenario {
    inline for (std.meta.tags(demo.Scenario)) |scenario| if (std.ascii.eqlIgnoreCase(value, @tagName(scenario))) return scenario;
    return null;
}

fn put(allocator: std.mem.Allocator, db: *Database, tokens: anytype, writer: *std.Io.Writer) !bool {
    const id = parseInt(u64, tokens.next() orelse return fail(writer, "PUT requires an id")) catch return fail(writer, "invalid id");
    var ttl: u64 = 0;
    var coords: std.ArrayList(f32) = .empty;
    defer coords.deinit(allocator);
    while (tokens.next()) |token| {
        if (eq(token, "TTL")) {
            if (coords.items.len != 0) return fail(writer, "TTL must precede coordinates");
            ttl = parseInt(u64, tokens.next() orelse return fail(writer, "TTL requires milliseconds")) catch return fail(writer, "invalid TTL");
        } else try coords.append(allocator, std.fmt.parseFloat(f32, token) catch return fail(writer, "invalid coordinate"));
    }
    if (coords.items.len != db.config.dim) return fail(writer, "dimension mismatch");
    db.put(id, coords.items, ttl) catch |err| return failError(writer, err);
    try writer.writeAll("+QUEUED\r\n");
    return true;
}

fn get(db: *Database, tokens: anytype, writer: *std.Io.Writer) !bool {
    const id = parseInt(u64, tokens.next() orelse return fail(writer, "GET requires an id")) catch return fail(writer, "invalid id");
    if (tokens.next() != null) return fail(writer, "too many arguments");
    var guard = db.acquire() orelse {
        try writer.writeAll("$-1\r\n");
        return true;
    };
    defer guard.release();
    const coords = guard.snapshot.find(id) orelse {
        try writer.writeAll("$-1\r\n");
        return true;
    };
    try writer.print("@VECTOR {d}", .{coords.len});
    for (coords) |value| try writer.print(" {d}", .{value});
    try writer.writeAll("\r\n");
    return true;
}

fn remove(db: *Database, tokens: anytype, writer: *std.Io.Writer) !bool {
    const id = parseInt(u64, tokens.next() orelse return fail(writer, "DEL requires an id")) catch return fail(writer, "invalid id");
    const existed = db.remove(id) catch |err| return failError(writer, err);
    try writer.print(":{d}\r\n", .{@intFromBool(existed)});
    return true;
}

fn knn(allocator: std.mem.Allocator, db: *Database, tokens: anytype, writer: *std.Io.Writer) !bool {
    const count = parseInt(usize, tokens.next() orelse return fail(writer, "KNN requires a count")) catch return fail(writer, "invalid count");
    if (count > 10_000) return fail(writer, "count too large");
    const query = try parseVector(allocator, db.config.dim, tokens, writer) orelse return true;
    defer allocator.free(query);
    const matches = try allocator.alloc(Match, count);
    defer allocator.free(matches);
    var guard = db.acquire() orelse {
        try writer.writeAll("@MATCHES 0\r\n");
        return true;
    };
    defer guard.release();
    const result = try guard.snapshot.nearest(query, matches);
    return writeMatches(writer, result);
}

fn range(allocator: std.mem.Allocator, db: *Database, tokens: anytype, writer: *std.Io.Writer) !bool {
    const radius = std.fmt.parseFloat(f32, tokens.next() orelse return fail(writer, "RANGE requires a radius")) catch return fail(writer, "invalid radius");
    if (radius < 0) return fail(writer, "radius must be non-negative");
    const query = try parseVector(allocator, db.config.dim, tokens, writer) orelse return true;
    defer allocator.free(query);
    var guard = db.acquire() orelse {
        try writer.writeAll("@MATCHES 0\r\n");
        return true;
    };
    defer guard.release();
    const matches = try allocator.alloc(Match, guard.snapshot.count());
    defer allocator.free(matches);
    return writeMatches(writer, try guard.snapshot.within(query, radius, matches));
}

fn clusters(db: *Database, writer: *std.Io.Writer) !bool {
    var guard = db.acquire() orelse {
        try writer.writeAll("@CLUSTERS 0\r\n");
        return true;
    };
    defer guard.release();
    try writer.print("@CLUSTERS {d}\r\n", .{guard.snapshot.count()});
    for (guard.snapshot.topology.ids, guard.snapshot.clusters) |id, cluster| try writer.print("{d} {d}\r\n", .{ id, cluster });
    return true;
}

fn stats(db: *Database, writer: *std.Io.Writer) !bool {
    var count: usize = 0;
    if (db.acquire()) |value| {
        var guard = value;
        count = guard.snapshot.count();
        guard.release();
    }
    try writer.print("@STATS generation={d} points={d} dirty={d} replayed={d} truncated_tail={d}\r\n", .{
        db.generation(), count, @intFromBool(db.pendingRebuild()), db.replay_stats.applied, @intFromBool(db.replay_stats.truncated_tail),
    });
    return true;
}

fn parseVector(allocator: std.mem.Allocator, dim: usize, tokens: anytype, writer: *std.Io.Writer) !?[]f32 {
    const query = try allocator.alloc(f32, dim);
    errdefer allocator.free(query);
    for (query) |*value| {
        const token = tokens.next() orelse {
            allocator.free(query);
            _ = try fail(writer, "dimension mismatch");
            return null;
        };
        value.* = std.fmt.parseFloat(f32, token) catch {
            allocator.free(query);
            _ = try fail(writer, "invalid coordinate");
            return null;
        };
    }
    if (tokens.next() != null) {
        allocator.free(query);
        _ = try fail(writer, "dimension mismatch");
        return null;
    }
    return query;
}

fn writeMatches(writer: *std.Io.Writer, matches: []const Match) !bool {
    try writer.print("@MATCHES {d}\r\n", .{matches.len});
    for (matches) |match| try writer.print("{d} {d}\r\n", .{ match.id, @sqrt(match.distance_squared) });
    return true;
}

fn parseInt(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10);
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn fail(writer: *std.Io.Writer, message: []const u8) !bool {
    try writer.print("-ERR {s}\r\n", .{message});
    return true;
}
fn failError(writer: *std.Io.Writer, err: anyerror) !bool {
    return fail(writer, @errorName(err));
}

test "protocol command matching is case insensitive" {
    try std.testing.expect(eq("pUt", "PUT"));
}
