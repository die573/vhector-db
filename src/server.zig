const std = @import("std");
const Database = @import("database.zig").Database;
const protocol = @import("protocol.zig");

pub fn serve(allocator: std.mem.Allocator, io: std.Io, db: *Database, host: []const u8, port: u16) !void {
    const address = try std.Io.net.IpAddress.parse(host, port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.log.info("listening on {s}:{d}", .{ host, port });
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("accept: {s}", .{@errorName(err)});
            continue;
        };
        const context = allocator.create(Client) catch {
            stream.close(io);
            continue;
        };
        context.* = .{ .allocator = allocator, .io = io, .db = db, .stream = stream };
        const thread = std.Thread.spawn(.{}, clientMain, .{context}) catch {
            stream.close(io);
            allocator.destroy(context);
            continue;
        };
        thread.detach();
    }
}

const Client = struct { allocator: std.mem.Allocator, io: std.Io, db: *Database, stream: std.Io.net.Stream };

fn clientMain(client: *Client) void {
    defer client.allocator.destroy(client);
    defer client.stream.close(client.io);
    handle(client.allocator, client.io, client.db, client.stream) catch |err| switch (err) {
        error.ReadFailed => {},
        else => std.log.warn("client closed: {s}", .{@errorName(err)}),
    };
}

fn handle(allocator: std.mem.Allocator, io: std.Io, db: *Database, stream: std.Io.net.Stream) !void {
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var socket_reader = stream.reader(io, &read_buffer);
    var socket_writer = stream.writer(io, &write_buffer);
    const reader = &socket_reader.interface;
    const writer = &socket_writer.interface;
    while (true) {
        const raw = (try reader.takeDelimiter('\n')) orelse return;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const keep_going = protocol.execute(allocator, db, line, writer) catch |err| {
            try writer.print("-ERR {s}\r\n", .{@errorName(err)});
            try writer.flush();
            continue;
        };
        try writer.flush();
        if (!keep_going) return;
    }
}
