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

//! `sample-tool mcp`: a minimal MCP server over standard input and output
//! (newline-delimited JSON-RPC 2.0), so that zstaller's `.mcp` option has
//! something real to package. It offers one tool, `sha256`, which hashes a
//! file.

const std = @import("std");
const Value = std.json.Value;

const default_protocol = "2025-06-18";
/// Written as `{}` (an empty `.{}` would be the empty array `[]`).
const empty: struct {} = .{};

pub fn serve(io: std.Io, gpa: std.mem.Allocator, version: []const u8) !void {
    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    while (true) {
        const line = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.MessageTooLong,
            else => |e| return e,
        } orelse return;
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        try handle(io, arena.allocator(), w, line, version);
        try w.flush();
    }
}

fn handle(io: std.Io, a: std.mem.Allocator, w: *std.Io.Writer, line: []const u8, version: []const u8) !void {
    const msg = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch
        return reply(w, .null, .{ .@"error" = .{ .code = -32700, .message = "Parse error" } });
    if (msg != .object) return reply(w, .null, .{ .@"error" = .{ .code = -32600, .message = "Invalid Request" } });
    // Notifications (no id) get no answer.
    const id = msg.object.get("id") orelse return;
    const method = switch (msg.object.get("method") orelse .null) {
        .string => |s| s,
        else => return reply(w, id, .{ .@"error" = .{ .code = -32600, .message = "Invalid Request" } }),
    };
    const params = msg.object.get("params") orelse Value{ .object = .empty };

    if (std.mem.eql(u8, method, "initialize")) {
        const protocol = switch (if (params == .object) params.object.get("protocolVersion") orelse .null else .null) {
            .string => |s| s,
            else => default_protocol,
        };
        return reply(w, id, .{ .result = .{
            .protocolVersion = protocol,
            .capabilities = .{ .tools = empty },
            .serverInfo = .{ .name = "sample", .version = version },
        } });
    }
    if (std.mem.eql(u8, method, "ping")) return reply(w, id, .{ .result = empty });
    if (std.mem.eql(u8, method, "tools/list")) return reply(w, id, .{ .result = .{ .tools = .{.{
        .name = "sha256",
        .description = "Returns the SHA-256 of a file as hexadecimal.",
        .inputSchema = .{
            .type = "object",
            .properties = .{ .path = .{ .type = "string", .description = "Path of the file to hash" } },
            .required = .{"path"},
        },
    }} } });
    if (std.mem.eql(u8, method, "tools/call")) {
        const path = blk: {
            if (params != .object) break :blk null;
            const name = params.object.get("name") orelse break :blk null;
            if (name != .string or !std.mem.eql(u8, name.string, "sha256")) break :blk null;
            const args = params.object.get("arguments") orelse break :blk null;
            if (args != .object) break :blk null;
            const p = args.object.get("path") orelse break :blk null;
            break :blk if (p == .string) p.string else null;
        } orelse return reply(w, id, .{ .@"error" = .{ .code = -32602, .message = "Expected the sha256 tool with a string 'path' argument" } });
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |err|
            return reply(w, id, .{ .result = .{
                .content = .{.{ .type = "text", .text = try std.fmt.allocPrint(a, "Cannot read {s}: {t}", .{ path, err }) }},
                .isError = true,
            } });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        return reply(w, id, .{ .result = .{
            .content = .{.{ .type = "text", .text = try std.fmt.allocPrint(a, "{x}", .{&digest}) }},
        } });
    }
    return reply(w, id, .{ .@"error" = .{ .code = -32601, .message = "Method not found" } });
}

fn reply(w: *std.Io.Writer, id: Value, body: anytype) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, w);
    inline for (@typeInfo(@TypeOf(body)).@"struct".fields) |f| {
        try w.print(",\"{s}\":", .{f.name});
        try std.json.Stringify.value(@field(body, f.name), .{}, w);
    }
    try w.writeAll("}\n");
}
