const std = @import("std");
const vhector = @import("vhector_db");

pub fn main(init: std.process.Init) !void {
    var options: vhector.demo.Options = .{};
    var mode: vhector.demo.Mode = .terminal;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--mode")) {
            i += 1;
            mode = std.meta.stringToEnum(vhector.demo.Mode, args[i]) orelse return error.InvalidMode;
        } else if (std.mem.eql(u8, args[i], "--scenario")) {
            i += 1;
            options.scenario = std.meta.stringToEnum(vhector.demo.Scenario, args[i]) orelse return error.InvalidScenario;
        } else if (std.mem.eql(u8, args[i], "--seconds")) {
            i += 1;
            options.seconds = try std.fmt.parseInt(u8, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--output")) {
            i += 1;
            options.output = args[i];
        } else if (std.mem.eql(u8, args[i], "--csv")) {
            i += 1;
            options.csv_path = args[i];
        } else return error.UnknownOption;
    }
    if (options.seconds == 0 or options.seconds > 30) return error.InvalidDuration;
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_file = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    switch (mode) {
        .terminal => try vhector.demo.runTerminal(std.heap.smp_allocator, init.io, &stdout_file.interface, options),
        .preview => try vhector.demo.runPreview(std.heap.smp_allocator, init.io, options),
        .video => {
            try vhector.demo.runVideo(std.heap.smp_allocator, init.io, options);
            std.debug.print("wrote {s}\n", .{options.output});
        },
    }
}
