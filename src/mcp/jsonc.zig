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

//! Adds and removes one entry of an object inside a JSON file, such as
//! `"mcpServers": { "myapp": {...} }` in `~/.claude.json`, by editing the
//! text in place. Everything else in the file stays byte for byte as it
//! was, including the comments and trailing commas VS Code allows in its
//! settings files (JSONC), which a parse and rewrite would lose.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{
    /// The text is not JSON (or JSONC), or its top level is not an object.
    InvalidJson,
    /// The member that should hold the entries is not an object.
    NotAnObject,
};

const Member = struct {
    /// Where its key starts.
    start: usize,
    value_start: usize,
    /// Just past its value.
    value_end: usize,
    /// The comma after its value, if there is one.
    comma_after: ?usize,
    /// The comma after the member before it, if there is one.
    comma_before: ?usize,
};

const Object = struct {
    /// The `{`.
    open: usize,
    /// The `}`.
    close: usize,
    members: usize,
    /// The start of the first member's key, if any.
    first: ?usize,
};

const Scanner = struct {
    text: []const u8,
    pos: usize = 0,
    /// How many arrays and objects the scanner is inside. Nesting deeper
    /// than `max_depth` is refused rather than recursed into, so a file
    /// cannot exhaust the stack.
    depth: usize = 0,

    const max_depth = 512;

    /// Skips white space and comments.
    fn skip(s: *Scanner) Error!void {
        while (s.pos < s.text.len) {
            switch (s.text[s.pos]) {
                ' ', '\t', '\r', '\n' => s.pos += 1,
                '/' => {
                    if (s.pos + 1 >= s.text.len) return error.InvalidJson;
                    switch (s.text[s.pos + 1]) {
                        '/' => {
                            const nl = std.mem.indexOfScalarPos(u8, s.text, s.pos, '\n') orelse s.text.len;
                            s.pos = nl;
                        },
                        '*' => {
                            const end = std.mem.indexOfPos(u8, s.text, s.pos + 2, "*/") orelse return error.InvalidJson;
                            s.pos = end + 2;
                        },
                        else => return error.InvalidJson,
                    }
                },
                else => return,
            }
        }
    }

    fn peek(s: *Scanner) Error!u8 {
        try s.skip();
        if (s.pos >= s.text.len) return error.InvalidJson;
        return s.text[s.pos];
    }

    /// Skips a string starting at `pos`, returning its raw contents.
    fn string(s: *Scanner) Error![]const u8 {
        if (s.text[s.pos] != '"') return error.InvalidJson;
        const start = s.pos + 1;
        var i = start;
        while (i < s.text.len) : (i += 1) switch (s.text[i]) {
            '\\' => i += 1,
            '"' => {
                s.pos = i + 1;
                return s.text[start..i];
            },
            '\n' => return error.InvalidJson,
            else => {},
        };
        return error.InvalidJson;
    }

    /// Skips any value starting at the next token.
    fn value(s: *Scanner) Error!void {
        if (s.depth == max_depth) return error.InvalidJson;
        s.depth += 1;
        defer s.depth -= 1;
        switch (try s.peek()) {
            '"' => _ = try s.string(),
            '{' => _ = try s.object(null),
            '[' => {
                s.pos += 1;
                while (true) {
                    if (try s.peek() == ']') break;
                    try s.value();
                    if (try s.peek() == ',') s.pos += 1 else break;
                }
                if (try s.peek() != ']') return error.InvalidJson;
                s.pos += 1;
            },
            else => {
                // Numbers, true, false, null.
                const start = s.pos;
                while (s.pos < s.text.len) : (s.pos += 1) switch (s.text[s.pos]) {
                    'a'...'z', 'A'...'Z', '0'...'9', '+', '-', '.' => {},
                    else => break,
                };
                if (s.pos == start) return error.InvalidJson;
            },
        }
    }

    /// Skips the object starting at the next token, noting the member
    /// named `wanted`.
    fn object(s: *Scanner, wanted: ?struct { key: []const u8, found: *?Member }) Error!Object {
        if (try s.peek() != '{') return error.NotAnObject;
        var obj: Object = .{ .open = s.pos, .close = undefined, .members = 0, .first = null };
        s.pos += 1;
        var comma_before: ?usize = null;
        while (try s.peek() != '}') {
            const start = s.pos;
            const key = try s.string();
            if (try s.peek() != ':') return error.InvalidJson;
            s.pos += 1;
            const value_start = blk: {
                _ = try s.peek();
                break :blk s.pos;
            };
            try s.value();
            const value_end = s.pos;
            if (obj.first == null) obj.first = start;
            obj.members += 1;
            const comma_after: ?usize = if (try s.peek() == ',') s.pos else null;
            if (wanted) |w| if (keyEquals(key, w.key)) {
                w.found.* = .{ .start = start, .value_start = value_start, .value_end = value_end, .comma_after = comma_after, .comma_before = comma_before };
            };
            if (comma_after) |c| {
                s.pos = c + 1;
                comma_before = c;
            } else break;
        }
        if (try s.peek() != '}') return error.InvalidJson;
        obj.close = s.pos;
        s.pos += 1;
        return obj;
    }
};

/// Whether the raw JSON string contents `raw` spell `key`. Keys with
/// escapes are compared after decoding the simple ones.
fn keyEquals(raw: []const u8, key: []const u8) bool {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return std.mem.eql(u8, raw, key);
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (n == buf.len) return false;
        var c = raw[i];
        if (c == '\\') {
            i += 1;
            if (i >= raw.len) return false;
            c = switch (raw[i]) {
                '"', '\\', '/' => raw[i],
                'u' => blk: {
                    if (i + 4 >= raw.len) return false;
                    const cp = std.fmt.parseInt(u8, raw[i + 3 .. i + 5], 16) catch return false;
                    if (!std.mem.eql(u8, raw[i + 1 .. i + 3], "00")) return false;
                    i += 4;
                    break :blk cp;
                },
                else => return false,
            };
        }
        buf[n] = c;
        n += 1;
    }
    return std.mem.eql(u8, buf[0..n], key);
}

const Found = struct {
    root: Object,
    /// The member holding the entries (`mcpServers`, `servers`).
    container: ?Member,
    container_obj: ?Object,
    entry: ?Member,
};

fn find(text: []const u8, container_key: []const u8, name: []const u8) Error!Found {
    // Editors on Windows may start the file with a byte order mark.
    var s: Scanner = .{ .text = text, .pos = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) 3 else 0 };
    var container: ?Member = null;
    const root = s.object(.{ .key = container_key, .found = &container }) catch |err| switch (err) {
        error.NotAnObject => return error.InvalidJson,
        else => |e| return e,
    };
    if (s.pos < text.len) {
        try s.skip();
        if (s.pos != text.len) return error.InvalidJson;
    }
    const c = container orelse return .{ .root = root, .container = null, .container_obj = null, .entry = null };
    var cs: Scanner = .{ .text = text, .pos = c.value_start };
    var entry: ?Member = null;
    const obj = try cs.object(.{ .key = name, .found = &entry });
    return .{ .root = root, .container = c, .container_obj = obj, .entry = entry };
}

/// The text of entry `name` in the object `container_key` at the top
/// level of `text`, or null.
pub fn get(text: []const u8, container_key: []const u8, name: []const u8) Error!?[]const u8 {
    if (isBlank(text)) return null;
    const f = try find(text, container_key, name);
    const e = f.entry orelse return null;
    return text[e.value_start..e.value_end];
}

/// `text` with entry `name` of `container_key` set to `value` (JSON on
/// one line). An empty `text` becomes a new file.
pub fn set(gpa: Allocator, text: []const u8, container_key: []const u8, name: []const u8, value: []const u8) Error![]u8 {
    if (isBlank(text)) return std.fmt.allocPrint(gpa, "{{\n  \"{s}\": {{\n    \"{s}\": {s}\n  }}\n}}\n", .{ container_key, name, value });
    const f = try find(text, container_key, name);
    if (f.entry) |e| return splice(gpa, text, e.value_start, e.value_end, value);
    // An object written on one line gets the entry on that line too.
    if (f.container_obj) |obj| if (obj.members > 0 and isOneLine(text, obj)) {
        const insert = try std.fmt.allocPrint(gpa, "\"{s}\":{s},", .{ name, value });
        defer gpa.free(insert);
        return splice(gpa, text, obj.open + 1, obj.open + 1, insert);
    };
    if (f.container_obj == null and f.root.members > 0 and isOneLine(text, f.root)) {
        const insert = try std.fmt.allocPrint(gpa, "\"{s}\":{{\"{s}\":{s}}},", .{ container_key, name, value });
        defer gpa.free(insert);
        return splice(gpa, text, f.root.open + 1, f.root.open + 1, insert);
    }
    const nl = newline(text);
    if (f.container_obj) |obj| {
        const indent = memberIndent(text, obj, f.container.?.start, "  ");
        const insert = if (obj.members == 0)
            try std.fmt.allocPrint(gpa, "{s}{s}\"{s}\": {s}{s}{s}", .{ nl, indent, name, value, nl, lineIndent(text, f.container.?.start) })
        else
            try std.fmt.allocPrint(gpa, "{s}{s}\"{s}\": {s},", .{ nl, indent, name, value });
        defer gpa.free(insert);
        // An empty object's contents (white space, comments) are kept
        // after the new entry only when there are members to follow.
        const end = if (obj.members == 0 and isBlank(text[obj.open + 1 .. obj.close])) obj.close else obj.open + 1;
        return splice(gpa, text, obj.open + 1, end, insert);
    }
    const indent = memberIndent(text, f.root, 0, "");
    const insert = try std.fmt.allocPrint(gpa, "{s}{s}\"{s}\": {{{s}{s}{s}\"{s}\": {s}{s}{s}}}{s}", .{
        nl, indent, container_key, nl, indent, indent, name, value, nl, indent, if (f.root.members > 0) "," else nl,
    });
    defer gpa.free(insert);
    const end = if (f.root.members == 0 and isBlank(text[f.root.open + 1 .. f.root.close])) f.root.close else f.root.open + 1;
    return splice(gpa, text, f.root.open + 1, end, insert);
}

/// `text` without entry `name` of `container_key`, or null when there is
/// no such entry.
pub fn remove(gpa: Allocator, text: []const u8, container_key: []const u8, name: []const u8) Error!?[]u8 {
    if (isBlank(text)) return null;
    const f = try find(text, container_key, name);
    return try removeMember(gpa, text, f.entry orelse return null);
}

/// `text` without the member `container_key` when it holds an empty
/// object (no entries, no comments), or null when there is no such member.
pub fn removeEmpty(gpa: Allocator, text: []const u8, container_key: []const u8) Error!?[]u8 {
    if (isBlank(text)) return null;
    const f = try find(text, container_key, "");
    const obj = f.container_obj orelse return null;
    if (obj.members > 0 or !isBlank(text[obj.open + 1 .. obj.close])) return null;
    return try removeMember(gpa, text, f.container.?);
}

/// Whether `text` is an object with nothing in it, as a file left once
/// its last member is removed.
pub fn isEmptyObject(text: []const u8) bool {
    const t = std.mem.trim(u8, if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text, " \t\r\n");
    return t.len >= 2 and t[0] == '{' and t[t.len - 1] == '}' and isBlank(t[1 .. t.len - 1]);
}

fn removeMember(gpa: Allocator, text: []const u8, e: Member) Allocator.Error![]u8 {
    var start = e.start;
    var end = e.value_end;
    if (e.comma_after) |c| {
        end = c + 1;
    } else if (e.comma_before) |c| {
        // The last member: take the comma before it, and the line break
        // and indentation that led to it, so the one before ends the
        // object as it did.
        return try splice(gpa, text, c, end, "");
    }
    // Whole lines, when the member had them to itself.
    const line_start = std.mem.lastIndexOfScalar(u8, text[0..start], '\n');
    const before = text[if (line_start) |l| l + 1 else 0..start];
    var after_end = end;
    while (after_end < text.len and (text[after_end] == ' ' or text[after_end] == '\t' or text[after_end] == '\r')) after_end += 1;
    if (isSpaces(before) and line_start != null and after_end < text.len and text[after_end] == '\n') {
        start = line_start.? + 1;
        end = after_end + 1;
    }
    return try splice(gpa, text, start, end, "");
}

fn splice(gpa: Allocator, text: []const u8, start: usize, end: usize, insert: []const u8) Allocator.Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ text[0..start], insert, text[end..] });
}

fn isOneLine(text: []const u8, obj: Object) bool {
    return std.mem.indexOfScalar(u8, text[obj.open..obj.close], '\n') == null;
}

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

fn isSpaces(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t").len == 0;
}

fn newline(text: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
}

/// The indentation of the line `pos` is on.
fn lineIndent(text: []const u8, pos: usize) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')) |l| l + 1 else 0;
    var end = start;
    while (end < pos and (text[end] == ' ' or text[end] == '\t')) end += 1;
    return text[start..end];
}

/// The indentation for a new member of `obj`: the first member's, or one
/// step more than the line the object starts on (owned by `owner_pos`).
fn memberIndent(text: []const u8, obj: Object, owner_pos: usize, fallback: []const u8) []const u8 {
    if (obj.first) |first| {
        const indent = lineIndent(text, first);
        // Only when the member starts its own line.
        if (first == (if (std.mem.lastIndexOfScalar(u8, text[0..first], '\n')) |l| l + 1 else 0) + indent.len) return indent;
    }
    const outer = lineIndent(text, owner_pos);
    if (outer.len == 0) return if (fallback.len > 0) fallback else "  ";
    const tabs = "\t" ** 16;
    const spaces = " " ** 32;
    return if (outer[0] == '\t') tabs[0..@min(tabs.len, outer.len + 1)] else spaces[0..@min(spaces.len, outer.len + 2)];
}

const testing = std.testing;

fn expectSet(before: []const u8, after: []const u8) !void {
    const out = try set(testing.allocator, before, "mcpServers", "app", "{\"command\":\"/usr/bin/app\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(after, out);
}

fn expectRemove(before: []const u8, after: ?[]const u8) !void {
    const out = try remove(testing.allocator, before, "mcpServers", "app");
    defer if (out) |o| testing.allocator.free(o);
    if (after) |a| try testing.expectEqualStrings(a, out.?) else try testing.expect(out == null);
}

test "set adds to an existing object, keeping everything else" {
    try expectSet(
        \\{
        \\  // my servers
        \\  "mcpServers": {
        \\    "other": { "command": "x" }, // keep
        \\  },
        \\  "theme": "dark"
        \\}
    ,
        \\{
        \\  // my servers
        \\  "mcpServers": {
        \\    "app": {"command":"/usr/bin/app"},
        \\    "other": { "command": "x" }, // keep
        \\  },
        \\  "theme": "dark"
        \\}
    );
}

test "set keeps a one-line object on one line" {
    try expectSet("{\"numStartups\": 2}", "{\"mcpServers\":{\"app\":{\"command\":\"/usr/bin/app\"}},\"numStartups\": 2}");
    try expectSet("{\"mcpServers\": {\"b\": 1}}", "{\"mcpServers\": {\"app\":{\"command\":\"/usr/bin/app\"},\"b\": 1}}");
}

test "set replaces an existing entry" {
    try expectSet(
        \\{"mcpServers":{"app":{"command":"old","args":[1,2]},"b":true}}
    ,
        \\{"mcpServers":{"app":{"command":"/usr/bin/app"},"b":true}}
    );
}

test "set creates the object and the file" {
    try expectSet(
        \\{
        \\  "numStartups": 12
        \\}
        \\
    ,
        \\{
        \\  "mcpServers": {
        \\    "app": {"command":"/usr/bin/app"}
        \\  },
        \\  "numStartups": 12
        \\}
        \\
    );
    try expectSet("{}",
        \\{
        \\  "mcpServers": {
        \\    "app": {"command":"/usr/bin/app"}
        \\  }
        \\}
    );
    try expectSet("",
        \\{
        \\  "mcpServers": {
        \\    "app": {"command":"/usr/bin/app"}
        \\  }
        \\}
        \\
    );
    try expectSet(
        \\{
        \\  "mcpServers": {}
        \\}
    ,
        \\{
        \\  "mcpServers": {
        \\    "app": {"command":"/usr/bin/app"}
        \\  }
        \\}
    );
}

test "a byte order mark is kept" {
    try expectSet("\xEF\xBB\xBF{\"mcpServers\":{}}", "\xEF\xBB\xBF{\"mcpServers\":{\n  \"app\": {\"command\":\"/usr/bin/app\"}\n}}");
}

test "set keeps Windows line endings" {
    try expectSet("{\r\n  \"a\": 1\r\n}\r\n", "{\r\n  \"mcpServers\": {\r\n    \"app\": {\"command\":\"/usr/bin/app\"}\r\n  },\r\n  \"a\": 1\r\n}\r\n");
}

test "remove takes the entry and its line" {
    try expectRemove(
        \\{
        \\  "mcpServers": {
        \\    "app": {"command":"/usr/bin/app"},
        \\    "other": {}
        \\  }
        \\}
    ,
        \\{
        \\  "mcpServers": {
        \\    "other": {}
        \\  }
        \\}
    );
    try expectRemove(
        \\{
        \\  "mcpServers": {
        \\    "other": {},
        \\    "app": {"command":"/usr/bin/app"}
        \\  }
        \\}
    ,
        \\{
        \\  "mcpServers": {
        \\    "other": {}
        \\  }
        \\}
    );
    try expectRemove(
        \\{
        \\  "mcpServers": {
        \\    "app": {"command":"/usr/bin/app"}
        \\  }
        \\}
    ,
        \\{
        \\  "mcpServers": {
        \\  }
        \\}
    );
    try expectRemove("{\"mcpServers\":{\"a\":1,\"app\":2,\"b\":3}}", "{\"mcpServers\":{\"a\":1,\"b\":3}}");
    try expectRemove("{\"mcpServers\":{\"a\":1}}", null);
    try expectRemove("{\"other\":{\"app\":1}}", null);
    try expectRemove("", null);
}

fn expectRemoveEmpty(before: []const u8, after: ?[]const u8) !void {
    const out = try removeEmpty(testing.allocator, before, "mcpServers");
    defer if (out) |o| testing.allocator.free(o);
    if (after) |a| try testing.expectEqualStrings(a, out.?) else try testing.expect(out == null);
}

test "an emptied container is removed, a kept one is not" {
    try expectRemoveEmpty(
        \\{
        \\  "numStartups": 3,
        \\  "mcpServers": {
        \\  },
        \\  "theme": "dark"
        \\}
    ,
        \\{
        \\  "numStartups": 3,
        \\  "theme": "dark"
        \\}
    );
    try expectRemoveEmpty("{\"a\":1,\"mcpServers\":{}}", "{\"a\":1}");
    try expectRemoveEmpty("{\n  \"mcpServers\": {}\n}\n", "{\n}\n");
    // Entries, or a comment the user left in it, keep it.
    try expectRemoveEmpty("{\"mcpServers\":{\"other\":{}}}", null);
    try expectRemoveEmpty("{\"mcpServers\":{ // mine\n}}", null);
    try expectRemoveEmpty("{\"other\":{}}", null);
    try testing.expect(isEmptyObject("\xEF\xBB\xBF{\n}\n"));
    try testing.expect(!isEmptyObject("{ // keep\n}"));
    try testing.expect(!isEmptyObject("{\"a\":1}"));
}

test "get finds only the entry in the right object" {
    const text =
        \\{ "projects": { "/x": { "mcpServers": { "app": 1 } } },
        \\  /* c */ "mcpServers": { "app": { "command": "a\"b" } } }
    ;
    try testing.expectEqualStrings("{ \"command\": \"a\\\"b\" }", (try get(text, "mcpServers", "app")).?);
    try testing.expect(try get(text, "mcpServers", "nope") == null);
}

test "rejects what is not a JSON object" {
    try testing.expectError(error.InvalidJson, get("[1]", "mcpServers", "app"));
    try testing.expectError(error.InvalidJson, get("{\"a\":1} x", "mcpServers", "app"));
    try testing.expectError(error.InvalidJson, get("{\"a\":1", "mcpServers", "app"));
    try testing.expectError(error.NotAnObject, set(testing.allocator, "{\"mcpServers\":null}", "mcpServers", "app", "{}"));
}

test "refuses nesting too deep to scan" {
    const deep = 100_000;
    const text = try testing.allocator.alloc(u8, "{\"x\":".len + 2 * deep + 1);
    defer testing.allocator.free(text);
    @memcpy(text[0..5], "{\"x\":");
    @memset(text[5..][0..deep], '[');
    @memset(text[5 + deep ..][0..deep], ']');
    text[text.len - 1] = '}';
    try testing.expectError(error.InvalidJson, get(text, "mcpServers", "app"));
    try testing.expect(try get("{\"x\":[[[{\"y\":[]}]]]}", "mcpServers", "app") == null);
}

test "keys with escapes" {
    try testing.expect(keyEquals("a\\u0062c", "abc"));
    try testing.expect(keyEquals("a\\/b", "a/b"));
    try testing.expect(!keyEquals("a\\nb", "a\nb"));
}
