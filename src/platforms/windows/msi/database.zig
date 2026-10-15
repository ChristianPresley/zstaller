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

//! Windows Installer database writer.
//!
//! An MSI file is a compound file (see `cfb.zig`) holding:
//!   * `_StringPool` / `_StringData`: every string used by any table.
//!   * `_Tables` / `_Columns`: the schema.
//!   * one stream per table, stored column by column.
//!   * `\x05SummaryInformation`: an OLE property set.
//!   * any binary streams (embedded cabinets, icons).
//! All stream names except the summary are compressed with the MSI name
//! encoding (`encodeStreamName`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const cfb = @import("cfb.zig");
const uuid = @import("../../../uuid.zig");

/// Column type bits as stored in `_Columns.Type`.
pub const ColumnType = struct {
    pub const valid: u16 = 0x0100;
    pub const localizable: u16 = 0x0200;
    pub const string: u16 = 0x0800;
    pub const nullable: u16 = 0x1000;
    pub const key: u16 = 0x2000;

    /// String column of at most `len` characters (0 = unlimited).
    pub fn str(len: u8) u16 {
        return 0x0D00 | @as(u16, len);
    }
    pub const int2: u16 = 0x0502;
    pub const int4: u16 = 0x0104;
    /// Binary (stream) column.
    pub const binary: u16 = 0x0900;
};

pub const Column = struct {
    name: []const u8,
    type: u16,

    fn isKey(c: Column) bool {
        return c.type & ColumnType.key != 0;
    }
    fn isNullable(c: Column) bool {
        return c.type & ColumnType.nullable != 0;
    }
    fn isBinary(c: Column) bool {
        return c.type & ~ColumnType.nullable & ~ColumnType.key == ColumnType.binary;
    }
    fn isString(c: Column) bool {
        return c.type & ColumnType.string != 0 and !c.isBinary();
    }
    fn width(c: Column) usize {
        if (c.isBinary() or c.isString()) return 2;
        return if (c.type & 0xff <= 2) 2 else 4;
    }
};

pub const Value = union(enum) {
    null,
    int: i32,
    str: []const u8,
    /// Binary column: the data is stored in the stream `<Table>.<key>`.
    stream: []const u8,
};

pub const Table = struct {
    name: []const u8,
    columns: []const Column,
    rows: std.ArrayList([]Value) = .empty,
};

pub const SummaryInfo = struct {
    title: []const u8 = "Installation Database",
    subject: []const u8,
    author: []const u8,
    keywords: []const u8 = "Installer",
    comments: []const u8,
    /// e.g. "x64;1033"
    template: []const u8,
    /// Package code GUID in `{...}` form.
    revision: []const u8,
    /// Seconds since the Unix epoch, used for create/save times.
    timestamp: u64,
    /// Minimum installer version x 100.
    page_count: i32 = 500,
    /// 2 = compressed source files.
    word_count: i32 = 2,
    application: []const u8 = "zstaller",
    security: i32 = 2,
};

pub const codepage: u16 = 1252;

/// Class id of MSI database root storages.
pub const msi_clsid = uuid.toWindowsBytes(uuid.parse("{000C1084-0000-0000-C000-000000000046}") catch unreachable);

pub const Error = Allocator.Error || Writer.Error || cfb.Error || error{
    NullInNonNullable,
    WrongColumnCount,
    DuplicateKey,
    NotRepresentable,
    StringTooLong,
    TooManyStrings,
    StreamNameTooLong,
};

pub const Database = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    tables: std.ArrayList(*Table) = .empty,
    /// Extra streams (name in plain form, encoded on write).
    streams: std.ArrayList(struct { name: []const u8, data: []const u8 }) = .empty,

    pub fn init(gpa: Allocator) Database {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(db: *Database) void {
        db.arena.deinit();
        db.* = undefined;
    }

    pub fn addTable(db: *Database, name: []const u8, columns: []const Column) Allocator.Error!*Table {
        const a = db.arena.allocator();
        const t = try a.create(Table);
        t.* = .{ .name = name, .columns = columns };
        try db.tables.append(a, t);
        return t;
    }

    /// Adds a row. Values are copied into the database.
    pub fn addRow(db: *Database, t: *Table, values: []const Value) Error!void {
        if (values.len != t.columns.len) return error.WrongColumnCount;
        const a = db.arena.allocator();
        const row = try a.alloc(Value, values.len);
        for (values, row, t.columns) |v, *r, c| {
            if (v == .null and !c.isNullable()) return error.NullInNonNullable;
            r.* = switch (v) {
                .null => .null,
                .int => |i| .{ .int = i },
                .str => |s| .{ .str = try toCodepage(a, s) },
                .stream => |s| .{ .stream = try a.dupe(u8, s) },
            };
        }
        try t.rows.append(a, row);
    }

    /// Adds a raw stream, e.g. an embedded cabinet.
    pub fn addStream(db: *Database, name: []const u8, data: []const u8) Allocator.Error!void {
        const a = db.arena.allocator();
        try db.streams.append(a, .{ .name = try a.dupe(u8, name), .data = data });
    }

    pub fn write(db: *Database, out: *Writer, summary: SummaryInfo) Error!void {
        var arena: std.heap.ArenaAllocator = .init(db.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // ---- String pool: ids assigned in sorted order, so sorting rows
        // by string id is the same as sorting by content.
        var counts: std.StringHashMapUnmanaged(u32) = .empty;
        for (db.tables.items) |t| {
            try bump(a, &counts, t.name); // _Tables
            for (t.columns) |c| {
                try bump(a, &counts, t.name); // _Columns.Table
                try bump(a, &counts, c.name); // _Columns.Name
            }
            for (t.rows.items) |row| for (row) |v| switch (v) {
                .str => |s| if (s.len > 0) try bump(a, &counts, s),
                else => {},
            };
        }
        const strings = try a.alloc([]const u8, counts.count());
        {
            var it = counts.keyIterator();
            var i: usize = 0;
            while (it.next()) |k| : (i += 1) strings[i] = k.*;
        }
        std.mem.sort([]const u8, strings, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        if (strings.len >= 0xFFFF) return error.TooManyStrings;
        var ids: std.StringHashMapUnmanaged(u16) = .empty;
        for (strings, 1..) |s, id| try ids.put(a, s, @intCast(id));

        var pool: Writer.Allocating = .init(a);
        var data: Writer.Allocating = .init(a);
        try pool.writer.writeInt(u32, codepage, .little);
        for (strings) |s| {
            if (s.len > 0xFFFF) return error.StringTooLong;
            try pool.writer.writeInt(u16, @intCast(s.len), .little);
            try pool.writer.writeInt(u16, @intCast(@min(counts.get(s).?, 0xFFFF)), .little);
            try data.writer.writeAll(s);
        }

        var streams: std.ArrayList(cfb.Stream) = .empty;
        try streams.append(a, .{ .name = try encodeStreamName(a, "_StringPool", true), .data = pool.written() });
        try streams.append(a, .{ .name = try encodeStreamName(a, "_StringData", true), .data = data.written() });

        // ---- _Tables and _Columns
        const sorted_tables = try a.dupe(*Table, db.tables.items);
        std.mem.sort(*Table, sorted_tables, {}, struct {
            fn lt(_: void, x: *Table, y: *Table) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        var tables_stream: Writer.Allocating = .init(a);
        for (sorted_tables) |t| try tables_stream.writer.writeInt(u16, ids.get(t.name).?, .little);
        try streams.append(a, .{ .name = try encodeStreamName(a, "_Tables", true), .data = tables_stream.written() });

        var col_count: usize = 0;
        for (sorted_tables) |t| col_count += t.columns.len;
        var cols: Writer.Allocating = .init(a);
        for (sorted_tables) |t| for (t.columns) |_| try cols.writer.writeInt(u16, ids.get(t.name).?, .little);
        for (sorted_tables) |t| for (t.columns, 1..) |_, n| try cols.writer.writeInt(u16, @intCast(n + 0x8000), .little);
        for (sorted_tables) |t| for (t.columns) |c| try cols.writer.writeInt(u16, ids.get(c.name).?, .little);
        for (sorted_tables) |t| for (t.columns) |c| try cols.writer.writeInt(u16, c.type ^ 0x8000, .little);
        std.debug.assert(cols.written().len == col_count * 8);
        try streams.append(a, .{ .name = try encodeStreamName(a, "_Columns", true), .data = cols.written() });

        // ---- Table data
        for (sorted_tables) |t| {
            if (t.rows.items.len == 0) continue;
            const encoded = try a.alloc([]u32, t.rows.items.len);
            for (t.rows.items, encoded) |row, *enc| {
                enc.* = try a.alloc(u32, row.len);
                for (row, enc.*, t.columns) |v, *e, c| e.* = encodeValue(v, c, &ids);
            }
            const Ctx = struct { cols: []const Column };
            std.mem.sort([]u32, encoded, Ctx{ .cols = t.columns }, struct {
                fn lt(ctx: Ctx, x: []u32, y: []u32) bool {
                    for (ctx.cols, x, y) |c, xv, yv| {
                        if (!c.isKey()) continue;
                        if (xv != yv) return xv < yv;
                    }
                    return false;
                }
            }.lt);
            for (encoded[1..], encoded[0 .. encoded.len - 1]) |y, x| {
                const same = for (t.columns, x, y) |c, xv, yv| {
                    if (c.isKey() and xv != yv) break false;
                } else true;
                if (same) return error.DuplicateKey;
            }
            var ts: Writer.Allocating = .init(a);
            for (t.columns, 0..) |c, ci| {
                for (encoded) |row| switch (c.width()) {
                    2 => try ts.writer.writeInt(u16, @truncate(row[ci]), .little),
                    4 => try ts.writer.writeInt(u32, row[ci], .little),
                    else => unreachable,
                };
            }
            try streams.append(a, .{ .name = try encodeStreamName(a, t.name, true), .data = ts.written() });

            // Binary columns live in their own streams named after the row's
            // primary key.
            for (t.rows.items) |row| for (row, t.columns) |v, c| {
                if (v != .stream) continue;
                _ = c;
                var name: std.ArrayList(u8) = .empty;
                try name.appendSlice(a, t.name);
                for (row, t.columns) |kv, kc| {
                    if (!kc.isKey()) continue;
                    try name.append(a, '.');
                    switch (kv) {
                        .str => |s| try name.appendSlice(a, s),
                        .int => |n| try name.print(a, "{d}", .{n}),
                        else => {},
                    }
                }
                try streams.append(a, .{ .name = try encodeStreamName(a, name.items, false), .data = v.stream });
            };
        }

        for (db.streams.items) |s| {
            try streams.append(a, .{ .name = try encodeStreamName(a, s.name, false), .data = s.data });
        }
        try streams.append(a, .{
            .name = std.unicode.utf8ToUtf16LeStringLiteral("\x05SummaryInformation"),
            .data = try summaryInformation(a, summary),
        });

        try cfb.write(db.gpa, out, msi_clsid, streams.items);
    }
};

fn bump(a: Allocator, counts: *std.StringHashMapUnmanaged(u32), s: []const u8) Allocator.Error!void {
    const gop = try counts.getOrPut(a, s);
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
}

fn encodeValue(v: Value, c: Column, ids: *const std.StringHashMapUnmanaged(u16)) u32 {
    return switch (v) {
        .null => 0,
        .str => |s| if (s.len == 0) 0 else ids.get(s).?,
        .stream => 1,
        .int => |i| if (c.width() == 2)
            @as(u16, @bitCast(@as(i16, @intCast(i)))) ^ 0x8000
        else
            @as(u32, @bitCast(i)) ^ 0x80000000,
    };
}

/// Converts UTF-8 to Windows-1252 for the characters both share (ASCII and
/// Latin-1). Other characters cannot be stored in a 1252 database.
fn toCodepage(a: Allocator, s: []const u8) Error![]const u8 {
    const ascii = for (s) |c| {
        if (c >= 0x80) break false;
    } else true;
    if (ascii) return a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    const view = std.unicode.Utf8View.init(s) catch return error.NotRepresentable;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x80 or (cp >= 0xA0 and cp <= 0xFF)) {
            try out.append(a, @intCast(cp));
        } else return error.NotRepresentable;
    }
    return out.items;
}

/// Encodes an MSI stream name. Pairs of characters from the set
/// `[0-9A-Za-z._]` are packed into one code unit (0x3800 + a + (b << 6)),
/// a trailing single one becomes 0x4800 + a, and table streams get a 0x4840
/// prefix. Other characters are kept as is.
pub fn encodeStreamName(a: Allocator, name: []const u8, is_table: bool) error{ OutOfMemory, StreamNameTooLong }![]const u16 {
    var out: std.ArrayList(u16) = .empty;
    if (is_table) try out.append(a, 0x4840);
    var i: usize = 0;
    while (i < name.len) {
        const c = name[i];
        if (mime(c)) |x| {
            if (i + 1 < name.len) {
                if (mime(name[i + 1])) |y| {
                    try out.append(a, 0x3800 + @as(u16, x) + (@as(u16, y) << 6));
                    i += 2;
                    continue;
                }
            }
            try out.append(a, 0x4800 + @as(u16, x));
        } else {
            try out.append(a, c);
        }
        i += 1;
    }
    if (out.items.len > 31) return error.StreamNameTooLong;
    return out.items;
}

fn mime(c: u8) ?u6 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'A'...'Z' => @intCast(c - 'A' + 10),
        'a'...'z' => @intCast(c - 'a' + 36),
        '.' => 62,
        '_' => 63,
        else => null,
    };
}

/// Builds the `\x05SummaryInformation` property set stream.
fn summaryInformation(a: Allocator, s: SummaryInfo) Error![]const u8 {
    const Prop = struct { id: u32, value: union(enum) { i2: i16, i4: i32, str: []const u8, time: u64 } };
    // FILETIME: 100 ns intervals since 1601-01-01.
    const filetime: u64 = (s.timestamp + 11644473600) * 10_000_000;
    const props = [_]Prop{
        .{ .id = 1, .value = .{ .i2 = @bitCast(codepage) } },
        .{ .id = 2, .value = .{ .str = s.title } },
        .{ .id = 3, .value = .{ .str = s.subject } },
        .{ .id = 4, .value = .{ .str = s.author } },
        .{ .id = 5, .value = .{ .str = s.keywords } },
        .{ .id = 6, .value = .{ .str = s.comments } },
        .{ .id = 7, .value = .{ .str = s.template } },
        .{ .id = 9, .value = .{ .str = s.revision } },
        .{ .id = 12, .value = .{ .time = filetime } },
        .{ .id = 13, .value = .{ .time = filetime } },
        .{ .id = 14, .value = .{ .i4 = s.page_count } },
        .{ .id = 15, .value = .{ .i4 = s.word_count } },
        .{ .id = 18, .value = .{ .str = s.application } },
        .{ .id = 19, .value = .{ .i4 = s.security } },
    };

    var body: Writer.Allocating = .init(a);
    var offsets: [props.len]u32 = undefined;
    const table_len = 8 + props.len * 8;
    for (props, &offsets) |p, *off| {
        off.* = @intCast(table_len + body.written().len);
        const w = &body.writer;
        switch (p.value) {
            .i2 => |v| {
                try w.writeInt(u32, 2, .little);
                try w.writeInt(i16, v, .little);
                try w.writeInt(u16, 0, .little);
            },
            .i4 => |v| {
                try w.writeInt(u32, 3, .little);
                try w.writeInt(i32, v, .little);
            },
            .time => |v| {
                try w.writeInt(u32, 64, .little);
                try w.writeInt(u64, v, .little);
            },
            .str => |v| {
                const text = try toCodepage(a, v);
                try w.writeInt(u32, 30, .little);
                try w.writeInt(u32, @intCast(text.len + 1), .little);
                try w.writeAll(text);
                try w.writeByte(0);
                try w.splatByteAll(0, (4 - (text.len + 1) % 4) % 4);
            },
        }
    }

    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeInt(u16, 0xFFFE, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u32, 0x00020006, .little); // Windows, version 6.2
    try w.splatByteAll(0, 16);
    try w.writeInt(u32, 1, .little);
    const fmtid = uuid.toWindowsBytes(uuid.parse("{F29F85E0-4FF9-1068-AB91-08002B27B3D9}") catch unreachable);
    try w.writeAll(&fmtid);
    try w.writeInt(u32, 48, .little);
    // Section
    try w.writeInt(u32, @intCast(table_len + body.written().len), .little);
    try w.writeInt(u32, props.len, .little);
    for (props, offsets) |p, off| {
        try w.writeInt(u32, p.id, .little);
        try w.writeInt(u32, off, .little);
    }
    try w.writeAll(body.written());
    return out.written();
}

const testing = std.testing;

test "stream name encoding" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "_Tables" as a table: prefix, then pairs ('_','T'), ('a','b'), ('l','e'), single 's'.
    const enc = try encodeStreamName(a, "_Tables", true);
    try testing.expectEqualSlices(u16, &.{
        0x4840,
        0x3800 + 63 + (29 << 6),
        0x3800 + 36 + (37 << 6),
        0x3800 + 47 + (40 << 6),
        0x4800 + 54,
    }, enc);
    const cab = try encodeStreamName(a, "a-b", false);
    try testing.expectEqualSlices(u16, &.{ 0x4800 + 36, '-', 0x4800 + 37 }, cab);
    try testing.expectError(error.StreamNameTooLong, encodeStreamName(a, "x" ** 63, false));
}

test "codepage conversion" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualSlices(u8, "Caf\xe9", try toCodepage(arena.allocator(), "Café"));
    try testing.expectError(error.NotRepresentable, toCodepage(arena.allocator(), "日本"));
}

test "database round trip through the compound file" {
    const gpa = testing.allocator;
    var db: Database = .init(gpa);
    defer db.deinit();
    const prop = try db.addTable("Property", &.{
        .{ .name = "Property", .type = ColumnType.str(72) | ColumnType.key },
        .{ .name = "Value", .type = ColumnType.str(0) | ColumnType.localizable },
    });
    try db.addRow(prop, &.{ .{ .str = "ProductName" }, .{ .str = "Demo" } });
    try db.addRow(prop, &.{ .{ .str = "ALLUSERS" }, .{ .str = "1" } });
    const media = try db.addTable("Media", &.{
        .{ .name = "DiskId", .type = ColumnType.int2 | ColumnType.key },
        .{ .name = "LastSequence", .type = ColumnType.int2 },
    });
    try db.addRow(media, &.{ .{ .int = 1 }, .{ .int = 3 } });
    try testing.expectError(error.NullInNonNullable, db.addRow(media, &.{ .{ .int = 2 }, .null }));
    try testing.expectError(error.WrongColumnCount, db.addRow(media, &.{.{ .int = 2 }}));

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try db.write(&out.writer, .{
        .subject = "Demo",
        .author = "Me",
        .comments = "c",
        .template = "x64;1033",
        .revision = "{00000000-0000-0000-0000-000000000000}",
        .timestamp = 0,
    });

    var r = try cfb.TestReader.init(gpa, out.written());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Strings sorted: ALLUSERS, DiskId, LastSequence, Media, ProductName, Property, Value, 1, Demo...
    const sdata = (try r.read(try encodeStreamName(a, "_StringData", true))).?;
    defer gpa.free(sdata);
    try testing.expect(std.mem.startsWith(u8, sdata, "1ALLUSERSDemoDiskIdLastSequenceMedia"));
    const prop_stream = (try r.read(try encodeStreamName(a, "Property", true))).?;
    defer gpa.free(prop_stream);
    // Two rows x two string columns, sorted: ALLUSERS (id 2) before ProductName.
    try testing.expectEqual(@as(usize, 8), prop_stream.len);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, prop_stream[0..2], .little));
    const media_stream = (try r.read(try encodeStreamName(a, "Media", true))).?;
    defer gpa.free(media_stream);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x80, 0x03, 0x80 }, media_stream);
    const summary = (try r.read(std.unicode.utf8ToUtf16LeStringLiteral("\x05SummaryInformation"))).?;
    defer gpa.free(summary);
    try testing.expectEqual(@as(u16, 0xFFFE), std.mem.readInt(u16, summary[0..2], .little));
}
