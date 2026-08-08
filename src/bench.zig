const std = @import("std");
const vhector = @import("vhector_db");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const dim = 8;
    const n = 2_000;
    var store = try vhector.Store.init(allocator, dim, 8, .{ .merge_cost = 0.25, .max_sweeps = 8 });
    defer store.deinit();
    var random = std.Random.DefaultPrng.init(0x5648_4543_544f_52);
    const ingest_start = std.Io.Clock.awake.now(init.io);
    for (0..n) |i| {
        var coords: [dim]f32 = undefined;
        for (&coords) |*value| value.* = random.random().float(f32) * 100;
        try store.put(i, &coords, 0, 0);
    }
    const ingest_ms = ingest_start.durationTo(std.Io.Clock.awake.now(init.io)).toMilliseconds();
    const rebuild_start = std.Io.Clock.awake.now(init.io);
    _ = try store.rebuild(0);
    const rebuild_ms = rebuild_start.durationTo(std.Io.Clock.awake.now(init.io)).toMilliseconds();
    var guard = store.acquire().?;
    defer guard.release();
    var matches: [10]vhector.store.Match = undefined;
    const query = [_]f32{50} ** dim;
    const query_start = std.Io.Clock.awake.now(init.io);
    var checksum: u64 = 0;
    for (0..1_000) |_| {
        const result = try guard.snapshot.nearest(&query, &matches);
        checksum +%= result[0].id;
    }
    const query_ms = query_start.durationTo(std.Io.Clock.awake.now(init.io)).toMilliseconds();
    std.debug.print("points={d} dim={d} ingest_ms={d} rebuild_ms={d} queries=1000 query_ms={d} checksum={d}\n", .{
        n, dim, ingest_ms, rebuild_ms, query_ms, checksum,
    });
}
