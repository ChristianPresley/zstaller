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

//! Writer for the common Unix `ar` archive format, as used by .deb packages.
//!
//! Members are written with uid/gid 0, mode 0644 and a caller-chosen mtime
//! so the output is reproducible. Member names are limited to 16 bytes
//! (the BSD/GNU long-name extensions are not needed for .deb).

const std = @import("std");
const Writer = std.Io.Writer;

pub const magic = "!<arch>\n";

pub const Error = Writer.Error || error{ NameTooLong, ValueTooLarge };

pub const ArWriter = struct {
    out: *Writer,

    /// Writes the global archive header.
    pub fn init(out: *Writer) Writer.Error!ArWriter {
        try out.writeAll(magic);
        return .{ .out = out };
    }

    /// Writes one member holding `data`.
    pub fn writeMember(a: ArWriter, name: []const u8, data: []const u8, mtime: u64) Error!void {
        try a.beginMember(name, data.len, mtime);
        try a.out.writeAll(data);
        try a.endMember(data.len);
    }

    /// Writes a member header for `size` bytes. The caller writes exactly
    /// `size` bytes and then calls `endMember(size)`.
    pub fn beginMember(a: ArWriter, name: []const u8, size: u64, mtime: u64) Error!void {
        if (name.len == 0 or name.len > 16) return error.NameTooLong;
        var h: [60]u8 = @splat(' ');
        @memcpy(h[0..name.len], name);
        try decimal(h[16..28], mtime);
        try decimal(h[28..34], 0);
        try decimal(h[34..40], 0);
        @memcpy(h[40..46], "100644");
        try decimal(h[48..58], size);
        h[58] = '`';
        h[59] = '\n';
        try a.out.writeAll(&h);
    }

    /// Writes the padding byte that keeps members 2-byte aligned.
    pub fn endMember(a: ArWriter, size: u64) Writer.Error!void {
        if (size % 2 == 1) try a.out.writeByte('\n');
    }
};

fn decimal(field: []u8, value: u64) error{ValueTooLarge}!void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
    if (s.len > field.len) return error.ValueTooLarge;
    @memcpy(field[0..s.len], s);
}

const testing = std.testing;

test "member layout matches ar(5)" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const a = try ArWriter.init(&w);
    try a.writeMember("debian-binary", "2.0\n", 0);
    try a.writeMember("odd", "abc", 1234);
    const expected = "!<arch>\n" ++
        "debian-binary   0           0     0     100644  4         `\n" ++
        "2.0\n" ++
        "odd             1234        0     0     100644  3         `\n" ++
        "abc\n";
    try testing.expectEqualStrings(expected, w.buffered());
}

test "rejects long names" {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const a = try ArWriter.init(&w);
    try testing.expectError(error.NameTooLong, a.writeMember("x" ** 17, "", 0));
}
