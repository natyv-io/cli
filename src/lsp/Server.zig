//! The `.ntx` LSP server's dispatch loop. Stage 1 scope only (see
//! `~/.claude/plans/lexical-wishing-penguin.md`): the real lifecycle
//! (`initialize`/`initialized`/`shutdown`/`exit`) and nothing else --
//! anything else gets a real `MethodNotFound` error response (for
//! requests) or is silently ignored (for notifications, matching the LSP
//! spec's own "unknown notifications must be ignored" requirement), rather
//! than a stub response, so later stages' manual testing sees an honest
//! "not implemented yet" instead of something that looks like it worked.
//!
//! `handleMessage` is a pure function (real JSON bytes in, real JSON bytes
//! out) deliberately kept separate from `run`'s real stdio loop -- lets
//! the dispatch logic itself be tested directly against fixture message
//! bytes with no real process/pipe involved, matching this project's own
//! "pure logic gets direct unit tests" split (`PositionMap.zig`,
//! `Transport.zig`).

const std = @import("std");
const Protocol = @import("Protocol.zig");

pub const HandleResult = struct {
    /// Populated only when a response must be sent back to the client --
    /// i.e. the incoming message was a real request (carried an `id`), not
    /// a notification. Owned by the caller, allocated via the `gpa` passed
    /// to `handleMessage`.
    response: ?[]u8 = null,
    /// Set only by a real `exit` notification -- tells `run`'s real stdio
    /// loop to stop reading after this message, matching the LSP spec's
    /// lifecycle (the client sends `exit` only after `shutdown` already
    /// completed).
    should_exit: bool = false,
};

/// Parses one already-length-delimited JSON-RPC message body (see
/// `Transport.readMessage`) and dispatches it. Never returns a Zig error
/// for a malformed *message* (bad JSON, missing `method`, unknown method)
/// -- those become real JSON-RPC error responses instead, exactly what a
/// real client expects back; a Zig error here means allocation failure,
/// nothing else.
pub fn handleMessage(gpa: std.mem.Allocator, body: []const u8) error{OutOfMemory}!HandleResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
        return .{ .response = try encodeError(gpa, .null, .parse_error, "request was not valid JSON") };
    };
    const obj = switch (value) {
        .object => |o| o,
        else => return .{ .response = try encodeError(gpa, .null, .invalid_request, "JSON-RPC message must be an object") },
    };

    const id: std.json.Value = obj.get("id") orelse .null;
    const is_request = obj.get("id") != null;

    const method_value = obj.get("method") orelse {
        return .{ .response = try encodeError(gpa, id, .invalid_request, "message has no 'method'") };
    };
    const method = switch (method_value) {
        .string => |s| s,
        else => return .{ .response = try encodeError(gpa, id, .invalid_request, "'method' must be a string") },
    };

    if (std.mem.eql(u8, method, "initialize")) {
        return .{ .response = try encodeResult(gpa, Protocol.InitializeResult, id, .{}) };
    }
    if (std.mem.eql(u8, method, "initialized")) {
        return .{}; // notification: server has nothing to do in response
    }
    if (std.mem.eql(u8, method, "shutdown")) {
        return .{ .response = try encodeNullResult(gpa, id) };
    }
    if (std.mem.eql(u8, method, "exit")) {
        return .{ .should_exit = true };
    }

    if (!is_request) return .{}; // unknown notification: ignore per spec
    return .{ .response = try encodeError(gpa, id, .method_not_found, "method not found") };
}

fn encodeResult(gpa: std.mem.Allocator, comptime Result: type, id: std.json.Value, result: Result) error{OutOfMemory}![]u8 {
    const Envelope = struct {
        jsonrpc: []const u8 = Protocol.version,
        id: std.json.Value,
        result: Result,
    };
    return std.json.Stringify.valueAlloc(gpa, Envelope{ .id = id, .result = result }, .{}) catch return error.OutOfMemory;
}

fn encodeNullResult(gpa: std.mem.Allocator, id: std.json.Value) error{OutOfMemory}![]u8 {
    return encodeResult(gpa, std.json.Value, id, .null);
}

fn encodeError(gpa: std.mem.Allocator, id: std.json.Value, code: Protocol.ErrorCode, message: []const u8) error{OutOfMemory}![]u8 {
    const Envelope = struct {
        jsonrpc: []const u8 = Protocol.version,
        id: std.json.Value,
        @"error": Protocol.ResponseError,
    };
    return std.json.Stringify.valueAlloc(gpa, Envelope{
        .id = id,
        .@"error" = .{ .code = @intFromEnum(code), .message = message },
    }, .{}) catch return error.OutOfMemory;
}

const Transport = @import("Transport.zig");

/// The real stdio loop: read one framed message, dispatch it, write back
/// whatever response (if any) resulted, repeat until `exit`. Every
/// `Transport`/`handleMessage` error is real and fatal here -- there's no
/// meaningful way to recover mid-stream from a broken framing layer or an
/// OOM, so `run` just surfaces the error to `main`, matching every other
/// CLI entry point in this repo.
pub fn run(gpa: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    while (true) {
        const body = try Transport.readMessage(reader, gpa);
        defer gpa.free(body);

        const result = try handleMessage(gpa, body);
        if (result.response) |response| {
            defer gpa.free(response);
            try Transport.writeMessage(writer, response);
        }
        if (result.should_exit) return;
    }
}

test "handleMessage: initialize returns a real result with empty capabilities" {
    const result = try handleMessage(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}", result.response.?);
    try std.testing.expect(!result.should_exit);
}

test "handleMessage: initialize echoes back a real string id, not just a number one" {
    const result = try handleMessage(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"initialize\",\"params\":{}}");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"result\":{\"capabilities\":{}}}", result.response.?);
}

test "handleMessage: initialized notification produces no response and doesn't exit" {
    const result = try handleMessage(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    try std.testing.expect(result.response == null);
    try std.testing.expect(!result.should_exit);
}

test "handleMessage: shutdown responds with a real null result" {
    const result = try handleMessage(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}", result.response.?);
}

test "handleMessage: exit notification produces no response but does signal should_exit" {
    const result = try handleMessage(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    try std.testing.expect(result.response == null);
    try std.testing.expect(result.should_exit);
}

test "handleMessage: an unknown request method gets a real MethodNotFound error, not silence" {
    const result = try handleMessage(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{}}");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}", result.response.?);
}

test "handleMessage: an unknown notification (no id) is silently ignored, not errored" {
    const result = try handleMessage(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"$/someUnknownNotification\"}");
    try std.testing.expect(result.response == null);
    try std.testing.expect(!result.should_exit);
}

test "handleMessage: malformed JSON gets a real ParseError response with a null id" {
    const result = try handleMessage(std.testing.allocator, "not json at all");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"request was not valid JSON\"}}", result.response.?);
}

test "handleMessage: a JSON value that isn't an object is a real InvalidRequest error" {
    const result = try handleMessage(std.testing.allocator, "[1,2,3]");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"JSON-RPC message must be an object\"}}", result.response.?);
}

test "run: a real initialize/initialized/shutdown/exit sequence produces exactly the two expected responses" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var input = std.Io.Writer.Allocating.init(gpa);
    defer input.deinit();
    try Transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    try Transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    try Transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}");
    try Transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var reader = std.Io.Reader.fixed(input.writer.buffered());
    try run(gpa, &reader, &aw.writer);

    const output = aw.writer.buffered();
    var out_reader = std.Io.Reader.fixed(output);
    const first = try Transport.readMessage(&out_reader, gpa);
    defer gpa.free(first);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}", first);
    const second = try Transport.readMessage(&out_reader, gpa);
    defer gpa.free(second);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}", second);
    try std.testing.expectError(error.EndOfStream, Transport.readMessage(&out_reader, gpa));
}
