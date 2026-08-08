const std = @import("std");

pub const Config = struct { host: []const u8 = "127.0.0.1", port: u16 = 6380 };

/// Cross-platform interactive VRESP client bundled with the server.
pub fn run(io: std.Io, config: Config) !void {
    const address = try std.Io.net.IpAddress.parse(config.host, config.port);
    const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var stdin_buffer: [16 * 1024]u8 = undefined;
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var socket_read_buffer: [64 * 1024]u8 = undefined;
    var socket_write_buffer: [16 * 1024]u8 = undefined;
    var stdin_file = std.Io.File.Reader.initStreaming(.stdin(), io, &stdin_buffer);
    var stdout_file = std.Io.File.Writer.init(.stdout(), io, &stdout_buffer);
    var socket_reader = stream.reader(io, &socket_read_buffer);
    var socket_writer = stream.writer(io, &socket_write_buffer);
    const input = &stdin_file.interface;
    const output = &stdout_file.interface;
    const remote = &socket_reader.interface;
    const send = &socket_writer.interface;

    try output.print("VhectorDB client connected to {s}:{d}\nType HELP for commands, QUIT to exit.\n", .{ config.host, config.port });
    while (true) {
        try output.writeAll("vhector> ");
        try output.flush();
        const raw = (try input.takeDelimiter('\n')) orelse break;
        const command = std.mem.trim(u8, raw, " \t\r");
        if (command.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(command, "HELP")) {
            try printHelp(output);
            continue;
        }
        if (isClearCommand(command)) {
            try output.writeAll("\x1b[2J\x1b[H");
            try output.flush();
            continue;
        }
        try send.writeAll(command);
        try send.writeAll("\r\n");
        try send.flush();
        if (!try printResponse(command, remote, output)) break;
    }
    try output.flush();
}

fn printResponse(command: []const u8, remote: *std.Io.Reader, output: *std.Io.Writer) !bool {
    const first = (try remote.takeDelimiter('\n')) orelse return false;
    const line = std.mem.trimEnd(u8, first, "\r");
    try output.print("{s}\n", .{line});

    var command_tokens = std.mem.tokenizeAny(u8, command, " \t");
    const name = command_tokens.next() orelse "";
    if (std.ascii.eqlIgnoreCase(name, "DEMO")) {
        const first_arg = command_tokens.next() orelse "";
        const mode = if (isDemoMode(first_arg)) first_arg else command_tokens.next() orelse "";
        if (std.ascii.eqlIgnoreCase(mode, "TERMINAL")) {
            while (true) {
                const raw = (try remote.takeDelimiter('\n')) orelse return false;
                const next = std.mem.trimEnd(u8, raw, "\r");
                try output.print("{s}\n", .{next});
                try output.flush();
                if (std.mem.eql(u8, next, "+DEMO DONE") or std.mem.startsWith(u8, next, "-ERR")) break;
            }
        } else if ((std.ascii.eqlIgnoreCase(mode, "VIDEO") and std.mem.eql(u8, line, "+DEMO RECORDING")) or
            (std.ascii.eqlIgnoreCase(mode, "PREVIEW") and std.mem.eql(u8, line, "+DEMO PREVIEWING")))
        {
            const raw = (try remote.takeDelimiter('\n')) orelse return false;
            try output.print("{s}\n", .{std.mem.trimEnd(u8, raw, "\r")});
        }
    } else if (rowCount(line)) |count| {
        for (0..count) |_| {
            const raw = (try remote.takeDelimiter('\n')) orelse return false;
            try output.print("{s}\n", .{std.mem.trimEnd(u8, raw, "\r")});
        }
    }
    try output.flush();
    return !std.ascii.eqlIgnoreCase(name, "QUIT");
}

fn rowCount(line: []const u8) ?usize {
    if (!std.mem.startsWith(u8, line, "@MATCHES ") and !std.mem.startsWith(u8, line, "@CLUSTERS ")) return null;
    const split = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return null;
    return std.fmt.parseInt(usize, line[split + 1 ..], 10) catch null;
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\PING
        \\PUT id [TTL milliseconds] x y [z ...]
        \\GET id
        \\DEL id
        \\KNN count x y [z ...]
        \\RANGE radius x y [z ...]
        \\CLUSTERS | REBUILD | STATS
        \\DEMO [scenario] TERMINAL [seconds]
        \\DEMO [scenario] PREVIEW [seconds]
        \\DEMO [scenario] VIDEO [seconds] [name.mp4]
        \\CLS | CLEAR (local terminal command)
        \\QUIT
        \\
    );
}

fn isDemoMode(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "TERMINAL") or std.ascii.eqlIgnoreCase(value, "PREVIEW") or std.ascii.eqlIgnoreCase(value, "VIDEO");
}

fn isClearCommand(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "CLS") or std.ascii.eqlIgnoreCase(value, "CLEAR");
}

test "client parses counted responses" {
    try std.testing.expectEqual(@as(?usize, 12), rowCount("@MATCHES 12"));
    try std.testing.expectEqual(@as(?usize, null), rowCount("+PONG"));
}

test "client clear commands are local and case insensitive" {
    try std.testing.expect(isClearCommand("cls"));
    try std.testing.expect(isClearCommand("ClEaR"));
    try std.testing.expect(!isClearCommand("CLEARLY"));
}
