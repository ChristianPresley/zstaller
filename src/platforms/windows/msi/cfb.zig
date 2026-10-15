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

//! Compound File Binary (CFB, "OLE structured storage") writer, version 3
//! with 512-byte sectors, as specified in [MS-CFB].
//!
//! Only a flat layout is supported: every stream is a direct child of the
//! root storage, which is all Windows Installer databases need. Streams
//! smaller than 4096 bytes go to the mini stream; larger ones are stored in
//! regular sectors. The output is deterministic.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const sector_size = 512;
pub const mini_sector_size = 64;
pub const mini_stream_cutoff = 4096;

pub const free_sect: u32 = 0xFFFFFFFF;
pub const end_of_chain: u32 = 0xFFFFFFFE;
pub const fat_sect: u32 = 0xFFFFFFFD;
pub const dif_sect: u32 = 0xFFFFFFFC;
pub const no_stream: u32 = 0xFFFFFFFF;

const signature = [8]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };
const header_difat_entries = 109;
const entries_per_sector = sector_size / 4;
const dir_entry_size = 128;

pub const Stream = struct {
    /// UTF-16 name, at most 31 code units.
    name: []const u16,
    data: []const u8,
};

pub const Error = Allocator.Error || Writer.Error || error{ InvalidName, DuplicateName, TooLarge };

/// Writes a compound file whose root storage has class id `root_clsid`
/// (in on-disk byte order) and contains `streams`.
pub fn write(gpa: Allocator, out: *Writer, root_clsid: [16]u8, streams: []const Stream) Error!void {
    // Sort children by the CFB name order so the directory can be laid out
    // as a balanced binary search tree.
    const order = try gpa.alloc(usize, streams.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, streams, struct {
        fn lt(s: []const Stream, a: usize, b: usize) bool {
            return compareNames(s[a].name, s[b].name) == .lt;
        }
    }.lt);
    for (streams) |s| {
        if (s.name.len == 0 or s.name.len > 31) return error.InvalidName;
        if (s.data.len > 0x7FFF0000) return error.TooLarge;
    }
    if (order.len > 1) for (order[1..], order[0 .. order.len - 1]) |b, a| {
        if (compareNames(streams[a].name, streams[b].name) == .eq) return error.DuplicateName;
    };

    // --- Layout -------------------------------------------------------
    var mini_sectors: u32 = 0;
    var big_sectors: u32 = 0;
    for (streams) |s| {
        if (s.data.len == 0) continue;
        if (s.data.len < mini_stream_cutoff) {
            mini_sectors += ceilDiv(s.data.len, mini_sector_size);
        } else {
            big_sectors += ceilDiv(s.data.len, sector_size);
        }
    }
    const mini_stream_len: u64 = @as(u64, mini_sectors) * mini_sector_size;
    const mini_stream_sectors = ceilDiv(mini_stream_len, sector_size);
    const minifat_sectors = ceilDiv(@as(u64, mini_sectors) * 4, sector_size);
    const dir_entries = streams.len + 1;
    const dir_sectors = ceilDiv(dir_entries * dir_entry_size, sector_size);
    const data_sectors: u64 = @as(u64, dir_sectors) + minifat_sectors + mini_stream_sectors + big_sectors;

    var fat_sectors: u32 = 0;
    var difat_sectors: u32 = 0;
    while (true) {
        const total = data_sectors + fat_sectors + difat_sectors;
        const need_fat = ceilDiv(total, entries_per_sector);
        const need_difat: u32 = if (need_fat > header_difat_entries) ceilDiv(need_fat - header_difat_entries, entries_per_sector - 1) else 0;
        if (need_fat == fat_sectors and need_difat == difat_sectors) break;
        fat_sectors = need_fat;
        difat_sectors = need_difat;
    }
    const total_sectors: u32 = @intCast(data_sectors + fat_sectors + difat_sectors);

    // Sector numbering: FAT, DIFAT, directory, mini FAT, mini stream, streams.
    const fat_start: u32 = 0;
    const difat_start: u32 = fat_start + fat_sectors;
    const dir_start: u32 = difat_start + difat_sectors;
    const minifat_start: u32 = dir_start + dir_sectors;
    const ministream_start: u32 = minifat_start + minifat_sectors;
    var next_big: u32 = ministream_start + mini_stream_sectors;

    // --- FAT and mini FAT --------------------------------------------
    const fat = try gpa.alloc(u32, @as(usize, fat_sectors) * entries_per_sector);
    defer gpa.free(fat);
    @memset(fat, free_sect);
    for (0..fat_sectors) |i| fat[fat_start + i] = fat_sect;
    for (0..difat_sectors) |i| fat[difat_start + i] = dif_sect;
    chain(fat, dir_start, dir_sectors);
    chain(fat, minifat_start, minifat_sectors);
    chain(fat, ministream_start, mini_stream_sectors);

    const minifat = try gpa.alloc(u32, @as(usize, minifat_sectors) * entries_per_sector);
    defer gpa.free(minifat);
    @memset(minifat, free_sect);

    const start = try gpa.alloc(u32, streams.len);
    defer gpa.free(start);
    var next_mini: u32 = 0;
    for (streams, start) |s, *st| {
        if (s.data.len == 0) {
            st.* = end_of_chain;
        } else if (s.data.len < mini_stream_cutoff) {
            const n = ceilDiv(s.data.len, mini_sector_size);
            st.* = next_mini;
            chain(minifat, next_mini, n);
            next_mini += n;
        } else {
            const n = ceilDiv(s.data.len, sector_size);
            st.* = next_big;
            chain(fat, next_big, n);
            next_big += n;
        }
    }
    std.debug.assert(next_big == total_sectors);

    // --- Directory ----------------------------------------------------
    const dir = try gpa.alloc(u8, @as(usize, dir_sectors) * sector_size);
    defer gpa.free(dir);
    @memset(dir, 0);
    // Unused entries must have no siblings/children.
    var e: usize = dir_entries;
    while (e < dir.len / dir_entry_size) : (e += 1) {
        const d = dir[e * dir_entry_size ..][0..dir_entry_size];
        std.mem.writeInt(u32, d[68..72], no_stream, .little);
        std.mem.writeInt(u32, d[72..76], no_stream, .little);
        std.mem.writeInt(u32, d[76..80], no_stream, .little);
    }

    // Entry 0 is the root; entry i+1 is the i-th child in sorted order.
    const root_name = std.unicode.utf8ToUtf16LeStringLiteral("Root Entry");
    const tree = try gpa.alloc(Node, order.len);
    defer gpa.free(tree);
    for (tree) |*n| n.* = .{};
    const height = treeHeight(order.len);
    const root_child = buildTree(tree, 0, order.len, 0, height);
    writeDirEntry(dir[0..dir_entry_size], root_name, 5, 1, no_stream, no_stream, if (root_child) |c| @intCast(c + 1) else no_stream, root_clsid, if (mini_sectors == 0) end_of_chain else ministream_start, mini_stream_len);
    for (order, 0..) |si, pos| {
        const n = tree[pos];
        const s = streams[si];
        writeDirEntry(
            dir[(pos + 1) * dir_entry_size ..][0..dir_entry_size],
            s.name,
            2,
            if (n.red) 0 else 1,
            if (n.left) |l| @intCast(l + 1) else no_stream,
            if (n.right) |r| @intCast(r + 1) else no_stream,
            no_stream,
            @splat(0),
            start[si],
            s.data.len,
        );
    }

    // --- Header -------------------------------------------------------
    var h: [sector_size]u8 = @splat(0);
    @memcpy(h[0..8], &signature);
    std.mem.writeInt(u16, h[24..26], 0x003E, .little);
    std.mem.writeInt(u16, h[26..28], 0x0003, .little);
    std.mem.writeInt(u16, h[28..30], 0xFFFE, .little);
    std.mem.writeInt(u16, h[30..32], 9, .little);
    std.mem.writeInt(u16, h[32..34], 6, .little);
    std.mem.writeInt(u32, h[44..48], fat_sectors, .little);
    std.mem.writeInt(u32, h[48..52], dir_start, .little);
    std.mem.writeInt(u32, h[56..60], mini_stream_cutoff, .little);
    std.mem.writeInt(u32, h[60..64], if (minifat_sectors == 0) end_of_chain else minifat_start, .little);
    std.mem.writeInt(u32, h[64..68], minifat_sectors, .little);
    std.mem.writeInt(u32, h[68..72], if (difat_sectors == 0) end_of_chain else difat_start, .little);
    std.mem.writeInt(u32, h[72..76], difat_sectors, .little);
    for (0..header_difat_entries) |i| {
        const v: u32 = if (i < fat_sectors) fat_start + @as(u32, @intCast(i)) else free_sect;
        std.mem.writeInt(u32, h[76 + i * 4 ..][0..4], v, .little);
    }
    try out.writeAll(&h);

    // --- Sectors ------------------------------------------------------
    try out.writeSliceEndian(u32, fat, .little);
    var fat_index: u32 = header_difat_entries;
    for (0..difat_sectors) |d| {
        for (0..entries_per_sector - 1) |_| {
            try out.writeInt(u32, if (fat_index < fat_sectors) fat_start + fat_index else free_sect, .little);
            fat_index += 1;
        }
        const next: u32 = if (d + 1 < difat_sectors) difat_start + @as(u32, @intCast(d)) + 1 else end_of_chain;
        try out.writeInt(u32, next, .little);
    }
    try out.writeAll(dir);
    try out.writeSliceEndian(u32, minifat, .little);

    var mini_written: u64 = 0;
    for (streams) |s| {
        if (s.data.len == 0 or s.data.len >= mini_stream_cutoff) continue;
        try out.writeAll(s.data);
        const padded = @as(u64, ceilDiv(s.data.len, mini_sector_size)) * mini_sector_size;
        try out.splatByteAll(0, padded - s.data.len);
        mini_written += padded;
    }
    try out.splatByteAll(0, @as(u64, mini_stream_sectors) * sector_size - mini_written);

    for (streams) |s| {
        if (s.data.len < mini_stream_cutoff) continue;
        try out.writeAll(s.data);
        const padded = @as(u64, ceilDiv(s.data.len, sector_size)) * sector_size;
        try out.splatByteAll(0, padded - s.data.len);
    }
}

fn ceilDiv(n: u64, d: u64) u32 {
    return @intCast((n + d - 1) / d);
}

fn chain(table: []u32, first: u32, count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        table[first + i] = if (i + 1 == count) end_of_chain else first + i + 1;
    }
}

fn writeDirEntry(
    d: *[dir_entry_size]u8,
    name: []const u16,
    kind: u8,
    color: u8,
    left: u32,
    right: u32,
    child: u32,
    clsid: [16]u8,
    start_sector: u32,
    size: u64,
) void {
    for (name, 0..) |c, i| std.mem.writeInt(u16, d[i * 2 ..][0..2], c, .little);
    std.mem.writeInt(u16, d[64..66], @intCast((name.len + 1) * 2), .little);
    d[66] = kind;
    d[67] = color;
    std.mem.writeInt(u32, d[68..72], left, .little);
    std.mem.writeInt(u32, d[72..76], right, .little);
    std.mem.writeInt(u32, d[76..80], child, .little);
    @memcpy(d[80..96], &clsid);
    std.mem.writeInt(u32, d[116..120], start_sector, .little);
    std.mem.writeInt(u64, d[120..128], size, .little);
}

/// CFB directory order: shorter names first, then by upper-cased code
/// units.
pub fn compareNames(a: []const u16, b: []const u16) std.math.Order {
    if (a.len != b.len) return std.math.order(a.len, b.len);
    for (a, b) |x, y| {
        const ux = upper(x);
        const uy = upper(y);
        if (ux != uy) return std.math.order(ux, uy);
    }
    return .eq;
}

fn upper(c: u16) u16 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

const Node = struct {
    left: ?usize = null,
    right: ?usize = null,
    red: bool = false,
};

fn treeHeight(n: usize) usize {
    var h: usize = 0;
    while ((@as(usize, 1) << @intCast(h + 1)) - 1 < n) h += 1;
    return h;
}

/// Builds a balanced BST over sorted positions [lo, hi). Nodes on the
/// deepest level of an incomplete tree are red and all others black, which
/// satisfies the red-black invariants.
fn buildTree(tree: []Node, lo: usize, hi: usize, depth: usize, height: usize) ?usize {
    if (lo >= hi) return null;
    const mid = lo + (hi - lo) / 2;
    tree[mid].left = buildTree(tree, lo, mid, depth + 1, height);
    tree[mid].right = buildTree(tree, mid + 1, hi, depth + 1, height);
    const perfect = (@as(usize, 1) << @intCast(height + 1)) - 1 == tree.len;
    tree[mid].red = depth == height and !perfect and height > 0;
    return mid;
}

// --- Test reader -------------------------------------------------------

/// Minimal reader used by tests to check the writer's output.
pub const TestReader = struct {
    bytes: []const u8,
    fat: []u32,
    minifat: []u32,
    dir: []const u8,
    ministream: []u8,
    gpa: Allocator,

    pub fn init(gpa: Allocator, bytes: []const u8) !TestReader {
        if (!std.mem.eql(u8, bytes[0..8], &signature)) return error.BadSignature;
        const nfat = std.mem.readInt(u32, bytes[44..48], .little);
        const dir_start = std.mem.readInt(u32, bytes[48..52], .little);
        const minifat_start = std.mem.readInt(u32, bytes[60..64], .little);
        const difat_start = std.mem.readInt(u32, bytes[68..72], .little);

        var fat_ids: std.ArrayList(u32) = .empty;
        defer fat_ids.deinit(gpa);
        for (0..@min(nfat, header_difat_entries)) |i| try fat_ids.append(gpa, std.mem.readInt(u32, bytes[76 + i * 4 ..][0..4], .little));
        var d = difat_start;
        while (d != end_of_chain and fat_ids.items.len < nfat) {
            const sec = sectorAt(bytes, d);
            for (0..entries_per_sector - 1) |i| {
                if (fat_ids.items.len < nfat) try fat_ids.append(gpa, std.mem.readInt(u32, sec[i * 4 ..][0..4], .little));
            }
            d = std.mem.readInt(u32, sec[sector_size - 4 ..][0..4], .little);
        }
        const fat = try gpa.alloc(u32, nfat * entries_per_sector);
        for (fat_ids.items, 0..) |id, i| {
            const sec = sectorAt(bytes, id);
            for (0..entries_per_sector) |j| fat[i * entries_per_sector + j] = std.mem.readInt(u32, sec[j * 4 ..][0..4], .little);
        }
        var r: TestReader = .{ .bytes = bytes, .fat = fat, .minifat = &.{}, .dir = &.{}, .ministream = &.{}, .gpa = gpa };
        r.dir = try r.readChain(dir_start, null);
        if (minifat_start != end_of_chain) {
            const mf = try r.readChain(minifat_start, null);
            defer gpa.free(mf);
            r.minifat = try gpa.alloc(u32, mf.len / 4);
            for (r.minifat, 0..) |*v, i| v.* = std.mem.readInt(u32, mf[i * 4 ..][0..4], .little);
        }
        const root_start = std.mem.readInt(u32, r.dir[116..120], .little);
        if (root_start != end_of_chain) r.ministream = try r.readChain(root_start, null);
        return r;
    }

    pub fn deinit(r: *TestReader) void {
        r.gpa.free(r.fat);
        r.gpa.free(r.minifat);
        r.gpa.free(@constCast(r.dir));
        r.gpa.free(r.ministream);
    }

    fn sectorAt(bytes: []const u8, id: u32) []const u8 {
        return bytes[(@as(usize, id) + 1) * sector_size ..][0..sector_size];
    }

    fn readChain(r: *TestReader, first: u32, size: ?u64) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var s = first;
        var guard: usize = 0;
        while (s != end_of_chain) : (guard += 1) {
            if (guard > r.fat.len) return error.Loop;
            try out.appendSlice(r.gpa, sectorAt(r.bytes, s));
            s = r.fat[s];
        }
        if (size) |n| out.shrinkRetainingCapacity(@intCast(n));
        return out.toOwnedSlice(r.gpa);
    }

    /// Returns a copy of the stream called `name`, or null.
    pub fn read(r: *TestReader, name: []const u16) !?[]u8 {
        var i: usize = 1;
        while (i * dir_entry_size < r.dir.len) : (i += 1) {
            const d = r.dir[i * dir_entry_size ..][0..dir_entry_size];
            if (d[66] != 2) continue;
            const len = std.mem.readInt(u16, d[64..66], .little) / 2 - 1;
            var matches = len == name.len;
            if (matches) for (name, 0..) |c, j| {
                if (std.mem.readInt(u16, d[j * 2 ..][0..2], .little) != c) matches = false;
            };
            if (!matches) continue;
            const start_sec = std.mem.readInt(u32, d[116..120], .little);
            const size = std.mem.readInt(u64, d[120..128], .little);
            if (size == 0) return try r.gpa.alloc(u8, 0);
            if (size >= mini_stream_cutoff) return try r.readChain(start_sec, size);
            var out: std.ArrayList(u8) = .empty;
            var s = start_sec;
            while (s != end_of_chain) {
                try out.appendSlice(r.gpa, r.ministream[@as(usize, s) * mini_sector_size ..][0..mini_sector_size]);
                s = r.minifat[s];
            }
            out.shrinkRetainingCapacity(@intCast(size));
            return try out.toOwnedSlice(r.gpa);
        }
        return null;
    }

    /// Checks the red-black tree under the root: BST order and equal black
    /// height. Returns the number of children reached.
    pub fn checkTree(r: *TestReader) !usize {
        const root_child = std.mem.readInt(u32, r.dir[76..80], .little);
        var count: usize = 0;
        _ = try r.walk(root_child, null, null, &count, false);
        return count;
    }

    fn entryName(r: *TestReader, id: u32) []const u16 {
        const d = r.dir[@as(usize, id) * dir_entry_size ..][0..dir_entry_size];
        const len = std.mem.readInt(u16, d[64..66], .little) / 2 - 1;
        return @as([*]const u16, @ptrCast(@alignCast(d.ptr)))[0..len];
    }

    fn walk(r: *TestReader, id: u32, lo: ?u32, hi: ?u32, count: *usize, parent_red: bool) !usize {
        if (id == no_stream) return 1;
        const d = r.dir[@as(usize, id) * dir_entry_size ..][0..dir_entry_size];
        const red = d[67] == 0;
        if (red and parent_red) return error.RedRed;
        if (lo) |l| if (compareNames(r.entryName(l), r.entryName(id)) != .lt) return error.Order;
        if (hi) |h| if (compareNames(r.entryName(id), r.entryName(h)) != .lt) return error.Order;
        count.* += 1;
        const left = std.mem.readInt(u32, d[68..72], .little);
        const right = std.mem.readInt(u32, d[72..76], .little);
        const bl = try r.walk(left, lo, id, count, red);
        const br = try r.walk(right, id, hi, count, red);
        if (bl != br) return error.BlackHeight;
        return bl + @intFromBool(!red);
    }
};

const testing = std.testing;

fn utf16(comptime s: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

test "round trip small, large and empty streams" {
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, 70_000);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    const streams = [_]Stream{
        .{ .name = utf16("small"), .data = "hello" },
        .{ .name = utf16("big"), .data = big },
        .{ .name = utf16("empty"), .data = "" },
        .{ .name = utf16("edge"), .data = "x" ** 4096 },
        .{ .name = utf16("under"), .data = "y" ** 4095 },
    };
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, @splat(0x11), &streams);
    try testing.expectEqual(@as(usize, 0), out.written().len % sector_size);

    var r = try TestReader.init(gpa, out.written());
    defer r.deinit();
    for (streams) |s| {
        const got = (try r.read(s.name)).?;
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, s.data, got);
    }
    try testing.expectEqual(streams.len, try r.checkTree());
}

test "directory tree is a valid red-black tree for many sizes" {
    const gpa = testing.allocator;
    var names: [40][8]u16 = undefined;
    var streams: [40]Stream = undefined;
    for (1..41) |n| {
        for (0..n) |i| {
            names[i] = .{ 'S', 't', 'r', @intCast('A' + i / 26), @intCast('a' + i % 26), '0', '1', '2' };
            // Vary the length too, since it is the primary sort key.
            streams[i] = .{ .name = names[i][0 .. 5 + (i % 4)], .data = "d" };
        }
        var out: Writer.Allocating = .init(gpa);
        defer out.deinit();
        try write(gpa, &out.writer, @splat(0), streams[0..n]);
        var r = try TestReader.init(gpa, out.written());
        defer r.deinit();
        try testing.expectEqual(n, try r.checkTree());
    }
}

test "needs DIFAT sectors beyond 109 FAT sectors" {
    const gpa = testing.allocator;
    // 109 FAT sectors cover 109*128*512 bytes (~7 MB); go past that.
    const big = try gpa.alloc(u8, 8 * 1024 * 1024);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i >> 9);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, @splat(0), &.{.{ .name = utf16("payload"), .data = big }});
    try testing.expect(std.mem.readInt(u32, out.written()[72..76], .little) >= 1);
    var r = try TestReader.init(gpa, out.written());
    defer r.deinit();
    const got = (try r.read(utf16("payload"))).?;
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, big, got);
}

test "rejects duplicate and invalid names" {
    const gpa = testing.allocator;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectError(error.DuplicateName, write(gpa, &out.writer, @splat(0), &.{
        .{ .name = utf16("abc"), .data = "" },
        .{ .name = utf16("ABC"), .data = "" },
    }));
    try testing.expectError(error.InvalidName, write(gpa, &out.writer, @splat(0), &.{
        .{ .name = utf16("x" ** 32), .data = "" },
    }));
}
