const std = @import("std");
const Store = @import("store.zig").Store;

const magic = "VH01";
const header_len = 13;
const Op = enum(u8) { put = 1, remove = 2 };

pub const ReplayStats = struct { applied: usize = 0, truncated_tail: bool = false };

/// Binary append-only persistence with checksummed, length-prefixed records.
/// A partial final record is ignored after a crash; corruption in a complete
/// record is reported instead of silently replaying invalid state.
pub const Aof = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    offset: u64,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Aof {
        return openDir(allocator, io, .cwd(), path);
    }

    pub fn openDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Aof {
        const file = try dir.createFile(io, path, .{ .read = true, .truncate = false });
        errdefer file.close(io);
        return .{ .allocator = allocator, .io = io, .file = file, .offset = try file.length(io) };
    }

    pub fn close(self: *Aof) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn appendPut(self: *Aof, id: u64, coords: []const f32, expires_at_ms: u64) !void {
        const payload_len = 8 + 8 + 4 + coords.len * 4;
        var payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);
        std.mem.writeInt(u64, payload[0..8], id, .little);
        std.mem.writeInt(u64, payload[8..16], expires_at_ms, .little);
        std.mem.writeInt(u32, payload[16..20], @intCast(coords.len), .little);
        for (coords, 0..) |value, i| std.mem.writeInt(u32, payload[20 + i * 4 ..][0..4], @bitCast(value), .little);
        try self.append(.put, payload);
    }

    pub fn appendRemove(self: *Aof, id: u64) !void {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, id, .little);
        try self.append(.remove, &payload);
    }

    pub fn sync(self: *Aof) !void {
        try self.file.sync(self.io);
    }

    pub fn replay(self: *Aof, store: *Store, now_ms: u64) !ReplayStats {
        const size: usize = @intCast(try self.file.length(self.io));
        if (size == 0) return .{};
        const bytes = try self.allocator.alloc(u8, size);
        defer self.allocator.free(bytes);
        const read = try self.file.readPositionalAll(self.io, bytes, 0);
        if (read != size) return error.UnexpectedEndOfFile;
        var stats: ReplayStats = .{};
        var cursor: usize = 0;
        while (cursor < bytes.len) {
            if (bytes.len - cursor < header_len) {
                stats.truncated_tail = true;
                break;
            }
            if (!std.mem.eql(u8, bytes[cursor..][0..4], magic)) return error.InvalidAofMagic;
            const op = std.enums.fromInt(Op, bytes[cursor + 4]) orelse return error.InvalidAofOperation;
            const len: usize = std.mem.readInt(u32, bytes[cursor + 5 ..][0..4], .little);
            const expected = std.mem.readInt(u32, bytes[cursor + 9 ..][0..4], .little);
            cursor += header_len;
            if (bytes.len - cursor < len) {
                stats.truncated_tail = true;
                break;
            }
            const payload = bytes[cursor..][0..len];
            if (checksum(payload) != expected) return error.AofChecksumMismatch;
            switch (op) {
                .put => try replayPut(store, payload, now_ms),
                .remove => {
                    if (payload.len != 8) return error.InvalidAofRecord;
                    _ = store.remove(std.mem.readInt(u64, payload[0..8], .little));
                },
            }
            stats.applied += 1;
            cursor += len;
        }
        return stats;
    }

    fn append(self: *Aof, op: Op, payload: []const u8) !void {
        var header: [header_len]u8 = undefined;
        @memcpy(header[0..4], magic);
        header[4] = @intFromEnum(op);
        std.mem.writeInt(u32, header[5..9], @intCast(payload.len), .little);
        std.mem.writeInt(u32, header[9..13], checksum(payload), .little);
        try self.file.writePositionalAll(self.io, &header, self.offset);
        try self.file.writePositionalAll(self.io, payload, self.offset + header.len);
        self.offset += header.len + payload.len;
    }
};

fn replayPut(store: *Store, payload: []const u8, now_ms: u64) !void {
    if (payload.len < 20) return error.InvalidAofRecord;
    const id = std.mem.readInt(u64, payload[0..8], .little);
    const expires = std.mem.readInt(u64, payload[8..16], .little);
    const dim: usize = std.mem.readInt(u32, payload[16..20], .little);
    if (payload.len != 20 + dim * 4) return error.InvalidAofRecord;
    if (expires != 0 and expires <= now_ms) return;
    const coords = try store.allocator.alloc(f32, dim);
    defer store.allocator.free(coords);
    for (coords, 0..) |*value, i| value.* = @bitCast(std.mem.readInt(u32, payload[20 + i * 4 ..][0..4], .little));
    try store.putExpiresAt(id, coords, expires);
}

fn checksum(bytes: []const u8) u32 {
    var hash: u32 = 2_166_136_261;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 16_777_619;
    }
    return hash;
}

test "AOF payload checksum changes with data" {
    try std.testing.expect(checksum("one") != checksum("two"));
}

test "AOF persists and replays mutations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try Aof.openDir(std.testing.allocator, std.testing.io, tmp.dir, "data.aof");
    defer log.close();
    try log.appendPut(7, &.{ 1.5, 2.5 }, 0);
    try log.appendPut(8, &.{ 9, 9 }, 10);
    try log.appendRemove(8);
    try log.sync();
    try std.testing.expect((try log.file.length(std.testing.io)) > 0);

    var store = try Store.init(std.testing.allocator, 2, 4, .{});
    defer store.deinit();
    const stats = try log.replay(&store, 100);
    try std.testing.expectEqual(@as(usize, 3), stats.applied);
    _ = try store.rebuild(100);
    var guard = store.acquire().?;
    defer guard.release();
    try std.testing.expect(guard.snapshot.find(7) != null);
    try std.testing.expect(guard.snapshot.find(8) == null);
}
