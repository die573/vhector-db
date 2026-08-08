const std = @import("std");
const vhector = @import("vhector_db");

const Config = struct { points: usize = 10_000, dim: usize = 8, queries: usize = 2_000, rounds: usize = 8, readers: usize = 4 };

pub fn main(init: std.process.Init) !void {
    var config: Config = .{};
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (i + 1 >= args.len) return error.MissingOptionValue;
        const option = args[i];
        i += 1;
        const value = try std.fmt.parseInt(usize, args[i], 10);
        if (std.mem.eql(u8, option, "--points")) config.points = value else if (std.mem.eql(u8, option, "--dim")) config.dim = value else if (std.mem.eql(u8, option, "--queries")) config.queries = value else if (std.mem.eql(u8, option, "--rounds")) config.rounds = value else if (std.mem.eql(u8, option, "--readers")) config.readers = value else return error.UnknownOption;
    }
    if (config.points < 2 or config.points > 100_000 or config.dim < 3 or config.dim > 32 or config.readers > 32) return error.InvalidStressConfig;
    try run(std.heap.smp_allocator, init.io, config);
}

fn run(allocator: std.mem.Allocator, io: std.Io, config: Config) !void {
    var store = try vhector.Store.init(allocator, config.dim, 8, .{ .merge_cost = 0.05, .max_sweeps = 4 });
    defer store.deinit();
    const coords = try allocator.alloc(f32, config.dim);
    defer allocator.free(coords);
    var rng = std.Random.DefaultPrng.init(0x5354_5245_5353_5648);

    const ingest_start = std.Io.Clock.awake.now(io);
    for (0..config.points) |point| {
        for (coords, 0..) |*value, d| value.* = rng.random().float(f32) * 1_000 + @as(f32, @floatFromInt(d));
        try store.put(point, coords, if (point % 7 == 0) 5_000 else 0, 0);
    }
    const ingest_ms = ingest_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

    const rebuild_start = std.Io.Clock.awake.now(io);
    _ = try store.rebuild(0);
    const rebuild_ms = rebuild_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

    var guard = store.acquire().?;
    var matches: [10]vhector.store.Match = undefined;
    @memset(coords, 500);
    const query_start = std.Io.Clock.awake.now(io);
    var checksum: u64 = 0;
    for (0..config.queries) |_| {
        const result = try guard.snapshot.nearest(coords, &matches);
        checksum +%= result[0].id;
    }
    const query_ms = query_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    guard.release();

    var shared = ReaderContext{ .store = &store, .dim = config.dim, .iterations = @max(config.queries / @max(config.readers, 1), 1) };
    const threads = try allocator.alloc(std.Thread, config.readers);
    defer allocator.free(threads);
    for (threads) |*thread| thread.* = try std.Thread.spawn(.{}, readerMain, .{&shared});
    const churn_start = std.Io.Clock.awake.now(io);
    for (0..config.rounds) |round| {
        for (0..@min(config.points, 500)) |point| {
            for (coords, 0..) |*value, d| value.* = @as(f32, @floatFromInt(point + round + d));
            try store.put(point, coords, 700, round * 250);
        }
        _ = try store.rebuild(round * 250);
    }
    for (threads) |thread| thread.join();
    store.collect();
    const churn_ms = churn_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    _ = try store.rebuild(10_000);
    var final = store.acquire().?;
    const final_count = final.snapshot.count();
    final.release();

    std.debug.print(
        "STRESS PASS points={d} dim={d} ingest_ms={d} rebuild_ms={d} queries={d} query_ms={d} rounds={d} readers={d} churn_ms={d} final={d} checksum={d}\n",
        .{ config.points, config.dim, ingest_ms, rebuild_ms, config.queries, query_ms, config.rounds, config.readers, churn_ms, final_count, checksum +% shared.checksum.load(.acquire) },
    );
}

const ReaderContext = struct {
    store: *vhector.Store,
    dim: usize,
    iterations: usize,
    checksum: std.atomic.Value(u64) = .init(0),
};

fn readerMain(context: *ReaderContext) void {
    var query: [32]f32 = [_]f32{500} ** 32;
    var matches: [4]vhector.store.Match = undefined;
    var checksum: u64 = 0;
    for (0..context.iterations) |_| {
        var guard = context.store.acquire() orelse continue;
        const result = guard.snapshot.nearest(query[0..context.dim], &matches) catch {
            guard.release();
            continue;
        };
        if (result.len != 0) checksum +%= result[0].id;
        guard.release();
    }
    _ = context.checksum.fetchAdd(checksum, .monotonic);
}
