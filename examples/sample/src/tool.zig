// Copyright 2026 The zstaller Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

//! A second program packaged with the sample through `programs` in
//! build.zig: a command-line tool installed next to `sample` (on PATH with
//! it, in /usr/bin on Ubuntu). Prints the version, or the SHA-256 of the
//! files it is given.
//!
//! On Windows the installers also run it as their install and uninstall
//! hooks (`after_install` and `before_uninstall` in build.zig):
//! `--register` writes machine-wide state to
//! `%ProgramData%\Zstaller Sample`, and `--unregister` removes it.
//!
//! `sample-tool mcp` runs it as an MCP server (src/mcp.zig), which
//! zstaller packages through `.mcp` in build.zig.

const std = @import("std");
const options = @import("options");
const mcp = @import("mcp.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        try w.print("sample-tool {s}\nUsage: sample-tool <file>...  prints the SHA-256 of each file\n       sample-tool mcp        runs as an MCP server on stdin and stdout\n", .{options.version});
        return w.flush();
    }
    if (std.mem.eql(u8, args[1], "mcp")) return mcp.serve(io, init.gpa, options.version);
    if (std.mem.eql(u8, args[1], "--register") or std.mem.eql(u8, args[1], "--unregister")) {
        const program_data = init.environ_map.get("ProgramData") orelse return error.NoProgramData;
        const dir = try std.fs.path.join(init.gpa, &.{ program_data, "Zstaller Sample" });
        defer init.gpa.free(dir);
        if (std.mem.eql(u8, args[1], "--register")) {
            var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
            defer d.close(io);
            try d.writeFile(io, .{ .sub_path = "registered.txt", .data = options.version });
        } else {
            try std.Io.Dir.cwd().deleteTree(io, dir);
        }
        return;
    }
    for (args[1..]) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, init.gpa, .unlimited);
        defer init.gpa.free(data);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        try w.print("{x}  {s}\n", .{ &digest, path });
    }
    try w.flush();
}
