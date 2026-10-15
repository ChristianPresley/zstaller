const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.writeAll("hello init\n");
    try w.interface.flush();
}
