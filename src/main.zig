const std = @import("std");
const vhector = @import("vhector_db");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len > 1 and std.mem.eql(u8, args[1], "client")) return runClient(init.io, args[2..]);

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 6380;
    var path: []const u8 = "vhector.aof";
    var config: vhector.database.Config = .{ .dim = 2 };
    var i: usize = if (args.len > 1 and std.mem.eql(u8, args[1], "server")) 2 else 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) return usage();
        if (std.mem.eql(u8, arg, "--sync")) {
            config.sync_on_write = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingOptionValue;
        i += 1;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--bind")) host = value else if (std.mem.eql(u8, arg, "--port")) port = try std.fmt.parseInt(u16, value, 10) else if (std.mem.eql(u8, arg, "--aof")) path = value else if (std.mem.eql(u8, arg, "--dim")) config.dim = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--neighbors")) config.graph_neighbors = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--rebuild-ms")) config.rebuild_interval_ms = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, arg, "--merge-cost")) config.clustering.merge_cost = try std.fmt.parseFloat(f64, value) else return error.UnknownOption;
    }

    var db = try vhector.Database.init(allocator, init.io, config, path);
    defer db.deinit();
    try db.start();
    std.log.info("vhector-db dim={d} aof={s}", .{ config.dim, path });
    try vhector.server.serve(allocator, init.io, &db, host, port);
}

fn usage() void {
    std.debug.print(
        \\vhector_db server [options]
        \\vhector_db client [--host ADDRESS] [--port PORT]
        \\
        \\Server options:
        \\  --bind ADDRESS       bind address (default 127.0.0.1)
        \\  --port PORT          TCP port (default 6380)
        \\  --aof PATH           append-only log (default vhector.aof)
        \\  --dim N              vector dimensions (default 2)
        \\  --neighbors N        high-dimensional graph degree (default 8)
        \\  --rebuild-ms N       snapshot rebuild interval (default 100)
        \\  --merge-cost FLOAT   Ward merge threshold (default 1.0)
        \\  --sync               fsync every mutation
        \\
    , .{});
}

fn runClient(io: std.Io, args: []const []const u8) !void {
    var config: vhector.client.Config = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help")) return usage();
        if (i + 1 >= args.len) return error.MissingOptionValue;
        const option = args[i];
        i += 1;
        if (std.mem.eql(u8, option, "--host")) config.host = args[i] else if (std.mem.eql(u8, option, "--port")) config.port = try std.fmt.parseInt(u16, args[i], 10) else return error.UnknownOption;
    }
    try vhector.client.run(io, config);
}
