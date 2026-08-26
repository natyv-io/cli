//! The `.ntx` LSP server's dispatch loop. Stage 1 (see
//! `~/.claude/plans/lexical-wishing-penguin.md`) covers the real lifecycle
//! (`initialize`/`initialized`/`shutdown`/`exit`); Stage 2 adds real
//! diagnostics on `textDocument/didOpen`/`didChange`/`didClose`. Anything
//! else still gets a real `MethodNotFound` error response (for requests)
//! or is silently ignored (for notifications, matching the LSP spec's own
//! "unknown notifications must be ignored" requirement), rather than a
//! stub response, so later stages' manual testing sees an honest "not
//! implemented yet" instead of something that looks like it worked.
//!
//! `handleMessage` is a pure function (real JSON bytes in, real JSON bytes
//! out) deliberately kept separate from `run`'s real stdio loop -- lets
//! the dispatch logic itself be tested directly against fixture message
//! bytes with no real process/pipe involved, matching this project's own
//! "pure logic gets direct unit tests" split (`PositionMap.zig`,
//! `Transport.zig`).

const std = @import("std");
const Protocol = @import("Protocol.zig");
const Diagnostics = @import("Diagnostics.zig");

pub const HandleResult = struct {
    /// Populated only when a response must be sent back to the client --
    /// i.e. the incoming message was a real request (carried an `id`), not
    /// a notification. Owned by the caller, allocated via the `gpa` passed
    /// to `handleMessage`.
    response: ?[]u8 = null,
    /// A server-*initiated* notification, unrelated to responding to the
    /// incoming message's own `id` -- today only ever
    /// `textDocument/publishDiagnostics`, produced as a side effect of a
    /// real `didOpen`/`didChange`/`didClose` notification (which never
    /// gets a `response` of its own, matching every other notification).
    /// Owned by the caller, same as `response`.
    notification: ?[]u8 = null,
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
pub fn handleMessage(gpa: std.mem.Allocator, body: []const u8) !HandleResult {
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
    if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        return .{ .notification = try handleDidOpen(gpa, obj.get("params") orelse .null) };
    }
    if (std.mem.eql(u8, method, "textDocument/didChange")) {
        return .{ .notification = try handleDidChange(gpa, obj.get("params") orelse .null) };
    }
    if (std.mem.eql(u8, method, "textDocument/didClose")) {
        return .{ .notification = try handleDidClose(gpa, obj.get("params") orelse .null) };
    }

    if (!is_request) return .{}; // unknown notification: ignore per spec
    return .{ .response = try encodeError(gpa, id, .method_not_found, "method not found") };
}

/// Reads `params.textDocument.<field>` as a string, or `null` if `params`
/// doesn't have that exact shape -- a real client always sends a
/// well-formed `didOpen`/`didChange`/`didClose`, so a malformed one here
/// means "nothing to publish," not a JSON-RPC error worth surfacing (these
/// are notifications; there is no `id` to attach an error response to
/// anyway).
fn textDocumentField(params: std.json.Value, field: []const u8) ?[]const u8 {
    const text_document = (params.object.get("textDocument") orelse return null);
    const value = text_document.object.get(field) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn handleDidOpen(gpa: std.mem.Allocator, params: std.json.Value) !?[]u8 {
    const uri = textDocumentField(params, "uri") orelse return null;
    const text = textDocumentField(params, "text") orelse return null;
    return try publishDiagnosticsFor(gpa, uri, text);
}

/// Full-sync mode only (`ServerCapabilities.textDocumentSync = 1`) --
/// `contentChanges`'s *last* entry always carries the document's entire
/// current text, not an incremental edit.
fn handleDidChange(gpa: std.mem.Allocator, params: std.json.Value) !?[]u8 {
    const uri = textDocumentField(params, "uri") orelse return null;
    const changes = switch (params.object.get("contentChanges") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    if (changes.items.len == 0) return null;
    const text = switch (changes.items[changes.items.len - 1]) {
        .object => |o| switch (o.get("text") orelse return null) {
            .string => |s| s,
            else => return null,
        },
        else => return null,
    };
    return try publishDiagnosticsFor(gpa, uri, text);
}

/// Publishes an empty diagnostics list for the closed document -- a
/// document that's no longer open can't still have live errors shown
/// against it in the editor.
fn handleDidClose(gpa: std.mem.Allocator, params: std.json.Value) !?[]u8 {
    const uri = textDocumentField(params, "uri") orelse return null;
    return try encodePublishDiagnostics(gpa, uri, &.{});
}

fn publishDiagnosticsFor(gpa: std.mem.Allocator, uri: []const u8, text: []const u8) !?[]u8 {
    const diag = try Diagnostics.compute(gpa, text);
    defer if (diag) |d| gpa.free(d.message);
    if (diag) |d| {
        const lsp_diagnostics = [_]Protocol.Diagnostic{.{
            .range = .{
                .start = .{ .line = d.line - 1, .character = d.col - 1 },
                .end = .{ .line = d.line - 1, .character = d.col - 1 },
            },
            .message = d.message,
        }};
        return try encodePublishDiagnostics(gpa, uri, &lsp_diagnostics);
    }
    return try encodePublishDiagnostics(gpa, uri, &.{});
}

fn encodePublishDiagnostics(gpa: std.mem.Allocator, uri: []const u8, diagnostics: []const Protocol.Diagnostic) ![]u8 {
    const Envelope = struct {
        jsonrpc: []const u8 = Protocol.version,
        method: []const u8 = "textDocument/publishDiagnostics",
        params: Protocol.PublishDiagnosticsParams,
    };
    return std.json.Stringify.valueAlloc(gpa, Envelope{
        .params = .{ .uri = uri, .diagnostics = diagnostics },
    }, .{}) catch return error.OutOfMemory;
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
        if (result.notification) |notification| {
            defer gpa.free(notification);
            try Transport.writeMessage(writer, notification);
        }
        if (result.should_exit) return;
    }
}

test "handleMessage: initialize returns a real result advertising full document sync" {
    const result = try handleMessage(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"textDocumentSync\":1}}}", result.response.?);
    try std.testing.expect(!result.should_exit);
}

test "handleMessage: initialize echoes back a real string id, not just a number one" {
    const result = try handleMessage(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"initialize\",\"params\":{}}");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"result\":{\"capabilities\":{\"textDocumentSync\":1}}}", result.response.?);
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
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"textDocumentSync\":1}}}", first);
    const second = try Transport.readMessage(&out_reader, gpa);
    defer gpa.free(second);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}", second);
    try std.testing.expectError(error.EndOfStream, Transport.readMessage(&out_reader, gpa));
}

// Mirrors examples/ntx-form/guest/form.go.ntx's own real, already-proven
// shape (no `parent={parent}` attribute -- `Container` doesn't take one).
const broken_ntx_source =
    \\package main
    \\
    \\expose Form
    \\
    \\func Form(parent widgets.Container) error {
    \\    <Container>
    \\}
    \\
;

const clean_ntx_source =
    \\package main
    \\
    \\expose Form
    \\
    \\func Form(parent widgets.Container) error {
    \\    <Container>
    \\    </Container>
    \\}
    \\
;

fn encodeDidOpen(gpa: std.mem.Allocator, uri: []const u8, text: []const u8) ![]u8 {
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8 = "textDocument/didOpen",
        params: struct { textDocument: struct { uri: []const u8, text: []const u8 } },
    };
    return std.json.Stringify.valueAlloc(gpa, Msg{ .params = .{ .textDocument = .{ .uri = uri, .text = text } } }, .{});
}

fn encodeDidChange(gpa: std.mem.Allocator, uri: []const u8, text: []const u8) ![]u8 {
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8 = "textDocument/didChange",
        params: struct {
            textDocument: struct { uri: []const u8 },
            contentChanges: []const struct { text: []const u8 },
        },
    };
    return std.json.Stringify.valueAlloc(gpa, Msg{
        .params = .{ .textDocument = .{ .uri = uri }, .contentChanges = &.{.{ .text = text }} },
    }, .{});
}

fn encodeDidClose(gpa: std.mem.Allocator, uri: []const u8) ![]u8 {
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8 = "textDocument/didClose",
        params: struct { textDocument: struct { uri: []const u8 } },
    };
    return std.json.Stringify.valueAlloc(gpa, Msg{ .params = .{ .textDocument = .{ .uri = uri } } }, .{});
}

test "handleMessage: didOpen with a clean .ntx document publishes empty diagnostics" {
    const gpa = std.testing.allocator;
    const body = try encodeDidOpen(gpa, "file:///test.go.ntx", clean_ntx_source);
    defer gpa.free(body);

    const result = try handleMessage(gpa, body);
    try std.testing.expect(result.response == null);
    defer gpa.free(result.notification.?);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///test.go.ntx\",\"diagnostics\":[]}}",
        result.notification.?,
    );
}

test "handleMessage: didOpen with a broken .ntx document publishes a real diagnostic with a real position" {
    const gpa = std.testing.allocator;
    const body = try encodeDidOpen(gpa, "file:///test.go.ntx", broken_ntx_source);
    defer gpa.free(body);

    const result = try handleMessage(gpa, body);
    defer gpa.free(result.notification.?);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, result.notification.?, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("file:///test.go.ntx", parsed.value.object.get("params").?.object.get("uri").?.string);
    const diagnostics = parsed.value.object.get("params").?.object.get("diagnostics").?.array;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    const diagnostic = diagnostics.items[0].object;
    try std.testing.expect(diagnostic.get("message").?.string.len > 0);
    const start = diagnostic.get("range").?.object.get("start").?.object;
    try std.testing.expect(start.get("line").?.integer >= 0);
    try std.testing.expect(start.get("character").?.integer >= 0);
}

test "handleMessage: didChange that fixes a broken document clears its diagnostics" {
    const gpa = std.testing.allocator;

    const open_body = try encodeDidOpen(gpa, "file:///test.go.ntx", broken_ntx_source);
    defer gpa.free(open_body);
    const open_result = try handleMessage(gpa, open_body);
    gpa.free(open_result.notification.?);

    const change_body = try encodeDidChange(gpa, "file:///test.go.ntx", clean_ntx_source);
    defer gpa.free(change_body);
    const change_result = try handleMessage(gpa, change_body);
    defer gpa.free(change_result.notification.?);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///test.go.ntx\",\"diagnostics\":[]}}",
        change_result.notification.?,
    );
}

test "handleMessage: didClose publishes an empty diagnostics list for that document" {
    const gpa = std.testing.allocator;
    const body = try encodeDidClose(gpa, "file:///test.go.ntx");
    defer gpa.free(body);

    const result = try handleMessage(gpa, body);
    defer gpa.free(result.notification.?);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///test.go.ntx\",\"diagnostics\":[]}}",
        result.notification.?,
    );
}
