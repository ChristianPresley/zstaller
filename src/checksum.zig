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

//! SHA-256 checksum sidecar files, in the format `sha256sum -c` accepts:
//! `<64 hex digits>  <file name>\n`.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Digest = [Sha256.digest_length]u8;

pub fn digest(data: []const u8) Digest {
    var out: Digest = undefined;
    Sha256.hash(data, &out, .{});
    return out;
}

/// Hashes the file at `sub_path` in `dir` without loading it all at once.
pub fn digestFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !Digest {
    var file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var h: Sha256 = .init(.{});
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        h.update(chunk);
        reader.interface.toss(chunk.len);
    }
    return h.finalResult();
}

/// Writes the sidecar line for `file_name` with digest `d`.
pub fn writeLine(w: *std.Io.Writer, d: Digest, file_name: []const u8) std.Io.Writer.Error!void {
    try w.print("{x}  {s}\n", .{ d, file_name });
}

test "known digest and sidecar line" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeLine(&w, digest("abc"), "a.deb");
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  a.deb\n",
        w.buffered(),
    );
}

test "digestFile matches digest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = "x" ** 200_000;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f", .data = data });
    const d = try digestFile(std.testing.io, tmp.dir, "f");
    try std.testing.expectEqual(digest(data), d);
}
