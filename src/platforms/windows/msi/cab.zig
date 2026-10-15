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

//! Microsoft Cabinet (.cab) writer, as specified in [MS-CAB].
//!
//! Writes a single-folder cabinet. Data is compressed with MSZIP (each
//! 32 KiB block is an independent DEFLATE stream prefixed with "CK"); if any
//! block would not fit MSZIP's size limit the folder is stored uncompressed
//! instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const deflate = @import("../../../archive/deflate.zig");

pub const File = struct {
    /// Name inside the cabinet. For Windows Installer this is the File
    /// table key.
    name: []const u8,
    data: []const u8,
};

pub const Compression = enum(u16) { none = 0, mszip = 1 };

const block_size = 32768;
const header_size = 36;
const folder_size = 8;
const file_header_size = 16;
const data_header_size = 8;
const attrib_archive: u16 = 0x20;
const attrib_utf8_name: u16 = 0x80;

pub const Error = Allocator.Error || Writer.Error || error{ TooManyFiles, TooLarge, InvalidName };

/// A file date and time in MS-DOS format, as CFFILE stores them.
pub const DosTime = struct {
    date: u16,
    time: u16,

    /// Converts seconds since the Unix epoch (UTC) to DOS format, which
    /// counts two-second steps from 1980 to 2107; values outside that range
    /// are clamped.
    pub fn fromUnix(secs: u64) DosTime {
        const epoch = std.time.epoch;
        const min: u64 = epoch.dos;
        const max: u64 = 4354819199; // 2107-12-31 23:59:59
        const es: epoch.EpochSeconds = .{ .secs = std.math.clamp(secs, min, max) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        return .{
            .date = @intCast((@as(u32, yd.year - 1980) << 9) | (@as(u32, md.month.numeric()) << 5) | (md.day_index + 1)),
            .time = @intCast((@as(u32, ds.getHoursIntoDay()) << 11) | (@as(u32, ds.getMinutesIntoHour()) << 5) | (ds.getSecondsIntoMinute() / 2)),
        };
    }
};

/// Writes `files` as one cabinet folder. `mtime` (seconds since the Unix
/// epoch) becomes every file's date; Windows Installer gives installed
/// files that date.
pub fn write(gpa: Allocator, out: *Writer, files: []const File, compression: Compression, mtime: u64) Error!void {
    const stamp: DosTime = .fromUnix(mtime);
    if (files.len > 0xFFFF) return error.TooManyFiles;
    var total: u64 = 0;
    for (files) |f| {
        if (f.name.len == 0 or f.name.len > 255 or std.mem.indexOfScalar(u8, f.name, 0) != null) return error.InvalidName;
        total += f.data.len;
    }
    if (total > 0x7FFF8000) return error.TooLarge;

    // Concatenate the folder's uncompressed data.
    const folder = try gpa.alloc(u8, @intCast(total));
    defer gpa.free(folder);
    var off: usize = 0;
    for (files) |f| {
        @memcpy(folder[off..][0..f.data.len], f.data);
        off += f.data.len;
    }

    var blocks: std.ArrayList([]const u8) = .empty;
    defer {
        for (blocks.items) |b| gpa.free(b);
        blocks.deinit(gpa);
    }
    var kind = compression;
    if (kind == .mszip) {
        var pos: usize = 0;
        while (pos < folder.len) : (pos += block_size) {
            const chunk = folder[pos..@min(pos + block_size, folder.len)];
            var buf: Writer.Allocating = .init(gpa);
            errdefer buf.deinit();
            buf.writer.writeAll("CK") catch return error.OutOfMemory;
            try deflate.compressTo(gpa, &buf.writer, chunk, .raw);
            const bytes = try buf.toOwnedSlice();
            if (bytes.len > block_size) {
                gpa.free(bytes);
                for (blocks.items) |b| gpa.free(b);
                blocks.clearRetainingCapacity();
                kind = .none;
                break;
            }
            try blocks.append(gpa, bytes);
        }
    }

    const num_blocks: usize = if (kind == .mszip) blocks.items.len else (folder.len + block_size - 1) / block_size;
    if (num_blocks > 0xFFFF) return error.TooLarge;

    var files_size: usize = 0;
    for (files) |f| files_size += file_header_size + f.name.len + 1;
    const data_start = header_size + folder_size + files_size;
    var data_size: usize = num_blocks * data_header_size;
    if (kind == .mszip) {
        for (blocks.items) |b| data_size += b.len;
    } else {
        data_size += folder.len;
    }
    const cab_size = data_start + data_size;
    if (cab_size > std.math.maxInt(u32)) return error.TooLarge;

    // CFHEADER
    try out.writeAll("MSCF");
    try out.writeInt(u32, 0, .little);
    try out.writeInt(u32, @intCast(cab_size), .little);
    try out.writeInt(u32, 0, .little);
    try out.writeInt(u32, header_size + folder_size, .little);
    try out.writeInt(u32, 0, .little);
    try out.writeAll(&.{ 3, 1 });
    try out.writeInt(u16, 1, .little);
    try out.writeInt(u16, @intCast(files.len), .little);
    try out.writeInt(u16, 0, .little);
    try out.writeInt(u16, 0, .little);
    try out.writeInt(u16, 0, .little);

    // CFFOLDER
    try out.writeInt(u32, @intCast(data_start), .little);
    try out.writeInt(u16, @intCast(num_blocks), .little);
    try out.writeInt(u16, @intFromEnum(kind), .little);

    // CFFILE entries
    var folder_off: u32 = 0;
    for (files) |f| {
        try out.writeInt(u32, @intCast(f.data.len), .little);
        try out.writeInt(u32, folder_off, .little);
        try out.writeInt(u16, 0, .little);
        try out.writeInt(u16, stamp.date, .little);
        try out.writeInt(u16, stamp.time, .little);
        const ascii = for (f.name) |c| {
            if (c >= 0x80) break false;
        } else true;
        try out.writeInt(u16, attrib_archive | (if (ascii) 0 else attrib_utf8_name), .little);
        try out.writeAll(f.name);
        try out.writeByte(0);
        folder_off += @intCast(f.data.len);
    }

    // CFDATA blocks
    for (0..num_blocks) |i| {
        const raw_len = @min(block_size, folder.len - i * block_size);
        const payload = if (kind == .mszip) blocks.items[i] else folder[i * block_size ..][0..raw_len];
        var sizes: [4]u8 = undefined;
        std.mem.writeInt(u16, sizes[0..2], @intCast(payload.len), .little);
        std.mem.writeInt(u16, sizes[2..4], @intCast(raw_len), .little);
        try out.writeInt(u32, checksum(&sizes, checksum(payload, 0)), .little);
        try out.writeAll(&sizes);
        try out.writeAll(payload);
    }
}

/// The CFDATA checksum from [MS-CAB] 2.6 (CSUMCompute): XOR of the data
/// as little-endian 32-bit words, with trailing bytes folded in reverse.
pub fn checksum(data: []const u8, seed: u32) u32 {
    var csum = seed;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) csum ^= std.mem.readInt(u32, data[i..][0..4], .little);
    var ul: u32 = 0;
    const rest = data[i..];
    switch (rest.len) {
        3 => ul = (@as(u32, rest[0]) << 16) | (@as(u32, rest[1]) << 8) | rest[2],
        2 => ul = (@as(u32, rest[0]) << 8) | rest[1],
        1 => ul = rest[0],
        else => {},
    }
    return csum ^ ul;
}

/// Extracts every file of a cabinet produced by `write` (test helper; it
/// supports exactly the subset `write` produces).
pub fn extractForTest(gpa: Allocator, cab: []const u8) !std.ArrayList(File) {
    if (!std.mem.eql(u8, cab[0..4], "MSCF")) return error.BadSignature;
    const coff_files = std.mem.readInt(u32, cab[16..20], .little);
    const nfiles = std.mem.readInt(u16, cab[28..30], .little);
    const data_start = std.mem.readInt(u32, cab[36..40], .little);
    const nblocks = std.mem.readInt(u16, cab[40..42], .little);
    const kind: Compression = @enumFromInt(std.mem.readInt(u16, cab[42..44], .little));

    var folder: std.ArrayList(u8) = .empty;
    defer folder.deinit(gpa);
    var p: usize = data_start;
    for (0..nblocks) |_| {
        const cb = std.mem.readInt(u16, cab[p + 4 ..][0..2], .little);
        const ucb = std.mem.readInt(u16, cab[p + 6 ..][0..2], .little);
        const payload = cab[p + 8 ..][0..cb];
        const stored = std.mem.readInt(u32, cab[p..][0..4], .little);
        if (stored != checksum(cab[p + 4 ..][0..4], checksum(payload, 0))) return error.BadChecksum;
        switch (kind) {
            .none => try folder.appendSlice(gpa, payload),
            .mszip => {
                if (!std.mem.eql(u8, payload[0..2], "CK")) return error.BadBlock;
                const raw = try deflate.decompress(gpa, payload[2..], .raw);
                defer gpa.free(raw);
                if (raw.len != ucb) return error.BadBlock;
                try folder.appendSlice(gpa, raw);
            },
        }
        p += 8 + cb;
    }

    var result: std.ArrayList(File) = .empty;
    errdefer result.deinit(gpa);
    var q: usize = coff_files;
    for (0..nfiles) |_| {
        const size = std.mem.readInt(u32, cab[q..][0..4], .little);
        const at = std.mem.readInt(u32, cab[q + 4 ..][0..4], .little);
        const name = std.mem.sliceTo(cab[q + 16 ..], 0);
        try result.append(gpa, .{ .name = name, .data = try gpa.dupe(u8, folder.items[at..][0..size]) });
        q += 16 + name.len + 1;
    }
    return result;
}

const testing = std.testing;

fn roundTrip(files: []const File, compression: Compression) !void {
    const gpa = testing.allocator;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, files, compression, std.time.epoch.dos);
    try testing.expectEqual(@as(u32, @intCast(out.written().len)), std.mem.readInt(u32, out.written()[8..12], .little));
    var got = try extractForTest(gpa, out.written());
    defer {
        for (got.items) |f| gpa.free(f.data);
        got.deinit(gpa);
    }
    try testing.expectEqual(files.len, got.items.len);
    for (files, got.items) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqualSlices(u8, a.data, b.data);
    }
}

test "round trip MSZIP and stored" {
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, 100_000);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i / 7);
    const files = [_]File{
        .{ .name = "F1", .data = big },
        .{ .name = "F2", .data = "hello world\n" },
        .{ .name = "F3", .data = "" },
    };
    try roundTrip(&files, .mszip);
    try roundTrip(&files, .none);
}

test "checksum folds trailing bytes in reverse order" {
    try testing.expectEqual(@as(u32, 0x04030201), checksum(&.{ 1, 2, 3, 4 }, 0));
    try testing.expectEqual(@as(u32, 0x04030201 ^ 0x050607), checksum(&.{ 1, 2, 3, 4, 5, 6, 7 }, 0));
    try testing.expectEqual(@as(u32, 0x0506), checksum(&.{ 5, 6 }, 0));
    try testing.expectEqual(@as(u32, 0xFF ^ 0x10), checksum(&.{0xFF}, 0x10));
}

test "incompressible data falls back to stored" {
    const gpa = testing.allocator;
    const noise = try gpa.alloc(u8, 70_000);
    defer gpa.free(noise);
    var prng: std.Random.DefaultPrng = .init(42);
    prng.random().bytes(noise);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, &.{.{ .name = "noise", .data = noise }}, .mszip, std.time.epoch.dos);
    const kind = std.mem.readInt(u16, out.written()[42..44], .little);
    try testing.expect(kind == 0 or kind == 1);
    try roundTrip(&.{.{ .name = "noise", .data = noise }}, .mszip);
}

test "DosTime.fromUnix" {
    const at_dos_epoch: DosTime = .fromUnix(std.time.epoch.dos);
    try std.testing.expectEqual(DosTime{ .date = (1 << 5) | 1, .time = 0 }, at_dos_epoch);
    // Earlier dates clamp to 1980-01-01.
    try std.testing.expectEqual(at_dos_epoch, DosTime.fromUnix(0));
    // 2026-10-15 05:11:41 UTC.
    try std.testing.expectEqual(DosTime{
        .date = (46 << 9) | (10 << 5) | 15,
        .time = (5 << 11) | (11 << 5) | 20,
    }, DosTime.fromUnix(1792041101));
    // Later dates clamp to 2107-12-31 23:59:58.
    try std.testing.expectEqual(DosTime{
        .date = (127 << 9) | (12 << 5) | 31,
        .time = (23 << 11) | (59 << 5) | 29,
    }, DosTime.fromUnix(std.math.maxInt(u64)));
}
