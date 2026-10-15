const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.writeAll("before exepath\n");
    try w.interface.flush();
    const p = try std.process.executablePathAlloc(init.io, init.arena.allocator());
    try w.interface.print("exe: {s}\n", .{p});
    try w.interface.flush();
}
