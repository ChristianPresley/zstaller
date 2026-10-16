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

const std = @import("std");
const options = @import("options");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        try w.print("sample-tool {s}\nUsage: sample-tool <file>...  prints the SHA-256 of each file\n", .{options.version});
        return w.flush();
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
