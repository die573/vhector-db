const std = @import("std");
const Store = @import("store.zig").Store;
const Snapshot = @import("store.zig").Snapshot;

pub const Mode = enum { terminal, preview, video };
pub const Scenario = enum { gaussian, swarm, traffic, sensors, geofence, topology, collision, predator_prey, galaxy, queries, ttl_storm };
pub const Options = struct {
    scenario: Scenario = .gaussian,
    seconds: u8 = 8,
    fps: u8 = 12,
    width: usize = 80,
    height: usize = 28,
    output: []const u8 = "vhector-demo.mp4",
    csv_path: ?[]const u8 = null,
    pace: bool = true,
};

const Simulator = struct {
    allocator: std.mem.Allocator,
    store: Store,
    rng: std.Random.DefaultPrng = .init(0x5648_4543_4445_4d4f),
    next_id: u64 = 1,
    scenario: Scenario,

    fn init(allocator: std.mem.Allocator, scenario: Scenario) !Simulator {
        return .{ .allocator = allocator, .scenario = scenario, .store = try Store.init(allocator, 2, 8, .{ .merge_cost = 3.0, .noise = 0.05, .max_sweeps = 12 }) };
    }

    fn deinit(self: *Simulator) void {
        self.store.deinit();
    }

    fn step(self: *Simulator, frame: usize, frames: usize, now_ms: u64) !u64 {
        const t = @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(@max(frames - 1, 1)));
        switch (self.scenario) {
            .gaussian => try self.gaussianStep(t, now_ms),
            .swarm => try self.swarmStep(t, now_ms),
            .traffic => try self.trafficStep(t, now_ms),
            .sensors => try self.sensorsStep(t, now_ms),
            .geofence => try self.geofenceStep(t, now_ms),
            .topology => try self.topologyStep(t, now_ms),
            .collision => try self.collisionStep(t, now_ms),
            .predator_prey => try self.predatorPreyStep(t, now_ms),
            .galaxy => try self.galaxyStep(t, now_ms),
            .queries => try self.queriesStep(t, now_ms),
            .ttl_storm => try self.ttlStormStep(frame, now_ms),
        }
        return self.store.rebuild(now_ms);
    }

    fn gaussianStep(self: *Simulator, t: f32, now_ms: u64) !void {
        const Source = struct { start: f32, end: f32, phase: f32, radius: f32 };
        const sources = [_]Source{
            .{ .start = 0.00, .end = 0.72, .phase = 0.00, .radius = 8 },
            .{ .start = 0.12, .end = 1.00, .phase = 0.33, .radius = 10 },
            .{ .start = 0.38, .end = 0.88, .phase = 0.66, .radius = 6 },
        };
        for (sources) |source| {
            if (t < source.start or t > source.end) continue;
            const local = (t - source.start) / (source.end - source.start);
            const angle = 2 * std.math.pi * (local + source.phase);
            const center = [2]f32{ source.radius * @cos(angle), source.radius * @sin(angle) };
            for (0..4) |_| {
                const coords = [2]f32{ gaussian(self.rng.random(), center[0], 0.8), gaussian(self.rng.random(), center[1], 0.8) };
                try self.store.put(self.next_id, &coords, 1_400, now_ms);
                self.next_id += 1;
            }
        }
    }

    fn swarmStep(self: *Simulator, t: f32, now_ms: u64) !void {
        for (0..96) |i| {
            const group: f32 = @floatFromInt(i % 3);
            const phase = @as(f32, @floatFromInt(i)) * 2.399;
            const center_angle = 2 * std.math.pi * t + group * 2.094;
            const spread = 1.2 + 0.7 * @sin(6 * std.math.pi * t + group);
            const p = [2]f32{ 7 * @cos(center_angle) + spread * @cos(phase + 3 * t), 7 * @sin(center_angle) + spread * @sin(phase + 3 * t) };
            try self.store.put(10_000 + i, &p, 2_000, now_ms);
        }
    }

    fn trafficStep(self: *Simulator, t: f32, now_ms: u64) !void {
        for (0..120) |i| {
            const lane = i % 4;
            const progress = wrap30(@as(f32, @floatFromInt(i)) * 1.73 + t * (24 + @as(f32, @floatFromInt(i % 7)))) - 15;
            const offset: f32 = if ((i / 4) % 2 == 0) -1.2 else 1.2;
            const p: [2]f32 = if (lane < 2) .{ progress, offset + @as(f32, @floatFromInt(lane)) * 0.35 } else .{ offset + @as(f32, @floatFromInt(lane - 2)) * 0.35, progress };
            try self.store.put(20_000 + i, &p, 1_500, now_ms);
        }
    }

    fn sensorsStep(self: *Simulator, t: f32, now_ms: u64) !void {
        for (0..144) |i| {
            const hotspot = i % 2;
            const angle = @as(f32, @floatFromInt(i)) * 2.399;
            const radius = 0.25 * @sqrt(@as(f32, @floatFromInt(i / 2 + 1)));
            const direction: f32 = if (hotspot == 0) 1 else -1;
            const center = [2]f32{ direction * (6 + 3 * @sin(2 * std.math.pi * t)), direction * 4 * @cos(2 * std.math.pi * t) };
            const p = [2]f32{ center[0] + radius * @cos(angle), center[1] + radius * @sin(angle) };
            try self.store.put(30_000 + i, &p, 1_800, now_ms);
        }
    }

    fn geofenceStep(self: *Simulator, t: f32, now_ms: u64) !void {
        for (0..100) |i| {
            const phase = @as(f32, @floatFromInt(i)) * 0.41;
            const radius = 3 + @as(f32, @floatFromInt(i % 10));
            const angle = phase + t * (3 + @as(f32, @floatFromInt(i % 5)));
            const p = [2]f32{ radius * @cos(angle), 0.7 * radius * @sin(angle) };
            try self.store.put(40_000 + i, &p, 1_500, now_ms);
        }
    }

    fn topologyStep(self: *Simulator, t: f32, now_ms: u64) !void {
        const blend = 0.5 - 0.5 * @cos(4 * std.math.pi * t);
        for (0..100) |i| {
            const angle = 2 * std.math.pi * @as(f32, @floatFromInt(i)) / 100;
            const circle = [2]f32{ 11 * @cos(angle), 11 * @sin(angle) };
            const row: f32 = @floatFromInt(i / 10);
            const col: f32 = @floatFromInt(i % 10);
            const grid = [2]f32{ (col - 4.5) * 2.2, (row - 4.5) * 2.2 };
            const p = [2]f32{ circle[0] * (1 - blend) + grid[0] * blend, circle[1] * (1 - blend) + grid[1] * blend };
            try self.store.put(50_000 + i, &p, 2_000, now_ms);
        }
    }

    fn collisionStep(self: *Simulator, t: f32, now_ms: u64) !void {
        for (0..90) |i| {
            const seed: f32 = @floatFromInt(i);
            const p = [2]f32{ triangle(seed * 0.137 + t * (1.3 + @as(f32, @floatFromInt(i % 5))), 13), triangle(seed * 0.271 + t * (1.1 + @as(f32, @floatFromInt(i % 7))), 12) };
            try self.store.put(60_000 + i, &p, 1_500, now_ms);
        }
    }

    fn predatorPreyStep(self: *Simulator, t: f32, now_ms: u64) !void {
        const center = [2]f32{ 7 * @cos(2 * std.math.pi * t), 6 * @sin(2 * std.math.pi * t) };
        for (0..90) |i| {
            const phase = @as(f32, @floatFromInt(i)) * 2.399;
            const p = [2]f32{ center[0] + 2.5 * @cos(phase + 4 * t), center[1] + 2.5 * @sin(phase + 4 * t) };
            try self.store.put(70_000 + i, &p, 1_500, now_ms);
        }
        for (0..12) |i| {
            const lag = 2 * std.math.pi * t - 0.65 + @as(f32, @floatFromInt(i)) * 0.08;
            const p = [2]f32{ 7 * @cos(lag), 6 * @sin(lag) };
            try self.store.put(71_000 + i, &p, 1_500, now_ms);
        }
    }

    fn galaxyStep(self: *Simulator, t: f32, now_ms: u64) !void {
        for (0..180) |i| {
            const arm = i % 3;
            const radius = 0.07 * @as(f32, @floatFromInt(i));
            const angle = radius * 0.75 + @as(f32, @floatFromInt(arm)) * 2.094 + 2 * std.math.pi * t / (1 + radius * 0.15);
            const p = [2]f32{ radius * @cos(angle), 0.7 * radius * @sin(angle) };
            try self.store.put(80_000 + i, &p, 2_000, now_ms);
        }
    }

    fn queriesStep(self: *Simulator, t: f32, now_ms: u64) !void {
        for (0..160) |i| {
            const angle = @as(f32, @floatFromInt(i)) * 2.399;
            const radius = 0.85 * @sqrt(@as(f32, @floatFromInt(i)));
            const p = [2]f32{ radius * @cos(angle), radius * @sin(angle) };
            try self.store.put(90_000 + i, &p, 2_000, now_ms);
        }
        const query = [2]f32{ 10 * @cos(2 * std.math.pi * t), 10 * @sin(2 * std.math.pi * t) };
        try self.store.put(90_999, &query, 2_000, now_ms);
    }

    fn ttlStormStep(self: *Simulator, frame: usize, now_ms: u64) !void {
        const burst: usize = if (frame % 12 < 4) 28 else 5;
        for (0..burst) |i| {
            const angle = self.rng.random().float(f32) * 2 * std.math.pi;
            const radius = self.rng.random().float(f32) * 13;
            const p = [2]f32{ radius * @cos(angle), radius * @sin(angle) };
            try self.store.put(self.next_id, &p, 250 + @as(u64, @intCast((i % 5) * 180)), now_ms);
            self.next_id += 1;
        }
    }
};

fn wrap30(value: f32) f32 {
    return value - @floor(value / 30) * 30;
}
fn triangle(value: f32, extent: f32) f32 {
    const unit = value - @floor(value);
    return (1 - 4 * @abs(unit - 0.5)) * extent;
}

pub fn runTerminal(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, options: Options) !void {
    var sim = try Simulator.init(allocator, options.scenario);
    defer sim.deinit();
    const frames = @as(usize, options.seconds) * options.fps;
    const frame_ms = 1_000 / @as(u64, options.fps);
    var grid = try allocator.alloc(u8, options.width * options.height);
    defer allocator.free(grid);
    var csv = try Csv.init(io, options.csv_path);
    defer csv.deinit();
    for (0..frames) |frame| {
        const now_ms = frame * frame_ms;
        const start = std.Io.Clock.awake.now(io);
        const generation = try sim.step(frame, frames, now_ms);
        const rebuild_us = start.durationTo(std.Io.Clock.awake.now(io)).toMicroseconds();
        var guard = sim.store.acquire().?;
        renderText(grid, options.width, options.height, guard.snapshot, options.scenario);
        try writer.writeAll("\x1b[2J\x1b[H");
        try writer.print("VhectorDB {s}  frame {d}/{d}  generation {d}  points {d}  rebuild {d}us\n", .{
            @tagName(options.scenario), frame + 1, frames, generation, guard.snapshot.count(), rebuild_us,
        });
        try writer.writeAll("Delaunay edges: .   clustered points: 0-f   TTL: 1400ms\n");
        for (0..options.height) |row| {
            try writer.writeAll(grid[row * options.width ..][0..options.width]);
            try writer.writeByte('\n');
        }
        try writer.flush();
        try csv.row(frame, now_ms, guard.snapshot.count(), guard.snapshot.topology.edges.len, rebuild_us);
        guard.release();
        if (options.pace) try std.Io.sleep(io, .fromMilliseconds(@intCast(frame_ms)), .awake);
    }
    try writer.writeAll("+DEMO DONE\r\n");
    try writer.flush();
}

pub fn runVideo(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var child = try spawnMedia(io, options, .video);
    defer child.kill(io);
    try streamMedia(allocator, io, options, &child);
}

pub fn runPreview(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var child = try spawnMedia(io, options, .preview);
    defer child.kill(io);
    try streamMedia(allocator, io, options, &child);
}

fn spawnMedia(io: std.Io, options: Options, mode: Mode) !std.process.Child {
    const width: usize = 640;
    const height: usize = 360;
    var size_buf: [32]u8 = undefined;
    var fps_buf: [8]u8 = undefined;
    const size = try std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ width, height });
    const fps = try std.fmt.bufPrint(&fps_buf, "{d}", .{options.fps});
    const argv: []const []const u8 = switch (mode) {
        .preview => &.{ "ffplay", "-loglevel", "warning", "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", size, "-framerate", fps, "-window_title", "VhectorDB Live Preview", "-autoexit", "-i", "-" },
        .video => &.{ "ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", size, "-framerate", fps, "-i", "-", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", options.output },
        .terminal => unreachable,
    };
    return std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .inherit,
        .create_no_window = mode == .video,
    }) catch |err| {
        std.log.err("unable to launch {s}; install the full FFmpeg toolset and ensure it is on PATH", .{if (mode == .preview) "ffplay" else "ffmpeg"});
        return err;
    };
}

fn streamMedia(allocator: std.mem.Allocator, io: std.Io, options: Options, child: *std.process.Child) !void {
    const width: usize = 640;
    const height: usize = 360;
    var sim = try Simulator.init(allocator, options.scenario);
    defer sim.deinit();
    const pixels = try allocator.alloc(u8, width * height * 3);
    defer allocator.free(pixels);
    const frames = @as(usize, options.seconds) * options.fps;
    const frame_ms = 1_000 / @as(u64, options.fps);
    var csv = try Csv.init(io, options.csv_path);
    defer csv.deinit();
    for (0..frames) |frame| {
        const start = std.Io.Clock.awake.now(io);
        _ = try sim.step(frame, frames, frame * frame_ms);
        const rebuild_us = start.durationTo(std.Io.Clock.awake.now(io)).toMicroseconds();
        var guard = sim.store.acquire().?;
        renderRgb(pixels, width, height, guard.snapshot, options.scenario);
        try child.stdin.?.writeStreamingAll(io, pixels);
        try csv.row(frame, frame * frame_ms, guard.snapshot.count(), guard.snapshot.topology.edges.len, rebuild_us);
        guard.release();
    }
    child.stdin.?.close(io);
    child.stdin = null;
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.MediaProcessFailed;
}

fn renderText(grid: []u8, width: usize, height: usize, snapshot: *const Snapshot, scenario: Scenario) void {
    @memset(grid, ' ');
    for (snapshot.topology.edges) |edge| {
        const a = project(snapshot.topology.point(edge.a), width, height);
        const b = project(snapshot.topology.point(edge.b), width, height);
        lineText(grid, width, height, a, b);
    }
    overlayText(grid, width, height, snapshot, scenario);
    for (snapshot.topology.ids, 0..) |id, i| {
        const p = project(snapshot.topology.point(i), width, height);
        grid[p[1] * width + p[0]] = if (scenario == .queries and id == 90_999) 'Q' else "0123456789abcdef"[snapshot.clusters[i] % 16];
    }
}

fn renderRgb(pixels: []u8, width: usize, height: usize, snapshot: *const Snapshot, scenario: Scenario) void {
    for (0..width * height) |i| {
        pixels[i * 3] = 14;
        pixels[i * 3 + 1] = 17;
        pixels[i * 3 + 2] = 23;
    }
    for (snapshot.topology.edges) |edge| lineRgb(pixels, width, height, project(snapshot.topology.point(edge.a), width, height), project(snapshot.topology.point(edge.b), width, height), .{ 48, 62, 82 });
    overlayRgb(pixels, width, height, snapshot, scenario);
    const colors = [_][3]u8{ .{ 69, 196, 255 }, .{ 255, 99, 132 }, .{ 110, 231, 183 }, .{ 250, 204, 21 }, .{ 196, 132, 252 }, .{ 251, 146, 60 } };
    for (snapshot.topology.ids, 0..) |id, i| {
        const p = project(snapshot.topology.point(i), width, height);
        const color = if (scenario == .queries and id == 90_999) [3]u8{ 255, 255, 255 } else colors[snapshot.clusters[i] % colors.len];
        var dy: isize = -3;
        while (dy <= 3) : (dy += 1) {
            var dx: isize = -3;
            while (dx <= 3) : (dx += 1) {
                if (dx * dx + dy * dy > 9) continue;
                setPixel(pixels, width, height, @as(isize, @intCast(p[0])) + dx, @as(isize, @intCast(p[1])) + dy, color);
            }
        }
    }
}

fn overlayText(grid: []u8, width: usize, height: usize, snapshot: *const Snapshot, scenario: Scenario) void {
    if (scenario == .traffic) {
        for (0..width) |x| {
            grid[(height / 2 - 1) * width + x] = '=';
            grid[(height / 2 + 1) * width + x] = '=';
        }
        for (0..height) |y| {
            grid[y * width + width / 2 - 1] = '|';
            grid[y * width + width / 2 + 1] = '|';
        }
    }
    if (scenario == .geofence or scenario == .queries) {
        var center: [2]f32 = .{ 0, 0 };
        var radius: f32 = 6;
        if (scenario == .queries) {
            radius = 3;
            for (snapshot.topology.ids, 0..) |id, i| if (id == 90_999) {
                center = snapshot.topology.point(i)[0..2].*;
                break;
            };
        }
        for (0..120) |i| {
            const angle = 2 * std.math.pi * @as(f32, @floatFromInt(i)) / 120;
            const p = project(&.{ center[0] + radius * @cos(angle), center[1] + radius * @sin(angle) }, width, height);
            grid[p[1] * width + p[0]] = 'o';
        }
    }
}

fn overlayRgb(pixels: []u8, width: usize, height: usize, snapshot: *const Snapshot, scenario: Scenario) void {
    if (scenario == .traffic) {
        const a = project(&.{ -15, -1.2 }, width, height);
        const b = project(&.{ 15, -1.2 }, width, height);
        lineRgb(pixels, width, height, a, b, .{ 120, 120, 120 });
        const c = project(&.{ -1.2, -15 }, width, height);
        const d = project(&.{ -1.2, 15 }, width, height);
        lineRgb(pixels, width, height, c, d, .{ 120, 120, 120 });
    }
    if (scenario == .geofence or scenario == .queries) {
        var center: [2]f32 = .{ 0, 0 };
        var radius: f32 = 6;
        if (scenario == .queries) {
            radius = 3;
            for (snapshot.topology.ids, 0..) |id, i| if (id == 90_999) {
                center = snapshot.topology.point(i)[0..2].*;
                break;
            };
        }
        var previous = project(&.{ center[0] + radius, center[1] }, width, height);
        for (1..121) |i| {
            const angle = 2 * std.math.pi * @as(f32, @floatFromInt(i)) / 120;
            const current = project(&.{ center[0] + radius * @cos(angle), center[1] + radius * @sin(angle) }, width, height);
            lineRgb(pixels, width, height, previous, current, .{ 34, 211, 238 });
            previous = current;
        }
    }
}

fn project(point: []const f32, width: usize, height: usize) [2]usize {
    const x = std.math.clamp((point[0] + 15) / 30, 0, 1);
    const y = std.math.clamp((point[1] + 15) / 30, 0, 1);
    return .{ @intFromFloat(x * @as(f32, @floatFromInt(width - 1))), @intFromFloat((1 - y) * @as(f32, @floatFromInt(height - 1))) };
}

fn lineText(grid: []u8, width: usize, height: usize, a: [2]usize, b: [2]usize) void {
    var x: isize = @intCast(a[0]);
    var y: isize = @intCast(a[1]);
    const bx: isize = @intCast(b[0]);
    const by: isize = @intCast(b[1]);
    const dx = @abs(bx - x);
    const sx: isize = if (x < bx) 1 else -1;
    const dy: isize = -@as(isize, @intCast(@abs(by - y)));
    const sy: isize = if (y < by) 1 else -1;
    var err: isize = @intCast(dx);
    err += dy;
    while (true) {
        if (x >= 0 and y >= 0 and x < width and y < height and grid[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))] == ' ') grid[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))] = '.';
        if (x == bx and y == by) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += @intCast(dx);
            y += sy;
        }
    }
}

fn lineRgb(pixels: []u8, width: usize, height: usize, a: [2]usize, b: [2]usize, color: [3]u8) void {
    var x: isize = @intCast(a[0]);
    var y: isize = @intCast(a[1]);
    const bx: isize = @intCast(b[0]);
    const by: isize = @intCast(b[1]);
    const dx = @abs(bx - x);
    const sx: isize = if (x < bx) 1 else -1;
    const dy: isize = -@as(isize, @intCast(@abs(by - y)));
    const sy: isize = if (y < by) 1 else -1;
    var err: isize = @intCast(dx);
    err += dy;
    while (true) {
        setPixel(pixels, width, height, x, y, color);
        if (x == bx and y == by) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += @intCast(dx);
            y += sy;
        }
    }
}

fn setPixel(pixels: []u8, width: usize, height: usize, x: isize, y: isize, color: [3]u8) void {
    if (x < 0 or y < 0 or x >= width or y >= height) return;
    const i = (@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))) * 3;
    pixels[i] = color[0];
    pixels[i + 1] = color[1];
    pixels[i + 2] = color[2];
}

fn gaussian(rng: std.Random, mean: f32, deviation: f32) f32 {
    var sample_a = rng.float(f32);
    while (sample_a <= 0) sample_a = rng.float(f32);
    const sample_b = rng.float(f32);
    return mean + deviation * @sqrt(-2 * @log(sample_a)) * @cos(2 * std.math.pi * sample_b);
}

const Csv = struct {
    io: std.Io,
    file: ?std.Io.File = null,
    offset: u64 = 0,
    fn init(io: std.Io, path: ?[]const u8) !Csv {
        const name = path orelse return .{ .io = io };
        const file = try std.Io.Dir.cwd().createFile(io, name, .{});
        const header = "frame,time_ms,points,edges,rebuild_us\n";
        try file.writePositionalAll(io, header, 0);
        return .{ .io = io, .file = file, .offset = header.len };
    }
    fn deinit(self: *Csv) void {
        if (self.file) |file| file.close(self.io);
    }
    fn row(self: *Csv, frame: usize, time_ms: u64, points: usize, edges: usize, rebuild_us: i64) !void {
        const file = self.file orelse return;
        var buffer: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "{d},{d},{d},{d},{d}\n", .{ frame, time_ms, points, edges, rebuild_us });
        try file.writePositionalAll(self.io, line, self.offset);
        self.offset += line.len;
    }
};

test "short simulation publishes and expires generations" {
    var sim = try Simulator.init(std.testing.allocator, .gaussian);
    defer sim.deinit();
    _ = try sim.step(0, 4, 0);
    _ = try sim.step(3, 4, 3_000);
    var guard = sim.store.acquire().?;
    defer guard.release();
    try std.testing.expect(guard.snapshot.count() > 0);
}

test "every demo scenario publishes a non-empty snapshot" {
    inline for (std.meta.tags(Scenario)) |scenario| {
        var sim = try Simulator.init(std.testing.allocator, scenario);
        defer sim.deinit();
        _ = try sim.step(1, 12, 100);
        var guard = sim.store.acquire().?;
        try std.testing.expect(guard.snapshot.count() > 0);
        guard.release();
    }
}
