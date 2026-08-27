//! The `.ntx` LSP server's dispatch loop. Stage 1 (see
//! `~/.claude/plans/lexical-wishing-penguin.md`) covers the real lifecycle
//! (`initialize`/`initialized`/`shutdown`/`exit`); Stage 2 adds real
//! diagnostics on `textDocument/didOpen`/`didChange`/`didClose`; Stage 3
//! adds real semantic tokens (`textDocument/semanticTokens/full`), which
//! is what first required `Server` to hold real per-connection state --
//! unlike diagnostics (recomputed from the full text a
//! `didOpen`/`didChange` notification already carries inline), a semantic
//! tokens *request* carries only a URI, per the real LSP spec, so the
//! server must already know that document's current text from an earlier
//! notification. Anything unimplemented still gets a real
//! `MethodNotFound` error response (for requests) or is silently ignored
//! (for notifications, matching the LSP spec's own "unknown notifications
//! must be ignored" requirement), rather than a stub response, so later
//! stages' manual testing sees an honest "not implemented yet" instead of
//! something that looks like it worked.
//!
//! `handleMessage` is a real method (real JSON bytes in, real JSON bytes
//! out) deliberately kept separate from `run`'s real stdio loop -- lets
//! the dispatch logic itself be tested directly against fixture message
//! bytes with no real process/pipe involved, matching this project's own
//! "pure logic gets direct unit tests" split (`PositionMap.zig`,
//! `Transport.zig`).

const std = @import("std");
const Io = std.Io;
const Protocol = @import("Protocol.zig");
const Diagnostics = @import("Diagnostics.zig");
const SemanticTokens = @import("SemanticTokens.zig");
const Transport = @import("Transport.zig");
const GoplsClientModule = @import("GoplsClient.zig");
const GoplsClient = GoplsClientModule.GoplsClient;
const Expose = @import("Expose");
const Codegen = @import("Codegen");
const PositionMap = Codegen.PositionMap;

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

/// Real per-connection server state -- as of Stage 3, just the currently
/// open documents' own text, keyed by URI (needed so a
/// `textDocument/semanticTokens/full` *request*, which per the real LSP
/// spec carries only a URI, can still be answered against the document's
/// actual current content).
pub const Server = struct {
    documents: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Stage 5: one real, persistent `gopls` child process per distinct Go
    /// module root (`GoplsClient.findModuleRoot`), reused across every
    /// `.ntx` document that root's own module contains -- lazily spawned
    /// on that root's first real hover request, never eagerly. Stored as
    /// `*GoplsClient` (heap-allocated via `gpa.create`), not `GoplsClient`
    /// by value: a `GoplsClient`'s own `reader`/`writer` fields hold
    /// pointers into its *own* `read_buf`/`write_buf` sibling fields, so
    /// storing it by value in a hash map would be unsound the moment the
    /// map resizes and moves its values to a new address -- a heap
    /// allocation's address never moves that way.
    gopls_clients: std.StringHashMapUnmanaged(*GoplsClient) = .empty,

    pub fn deinit(self: *Server, gpa: std.mem.Allocator, io: Io) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.documents.deinit(gpa);

        var git = self.gopls_clients.iterator();
        while (git.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(gpa, io);
            gpa.destroy(entry.value_ptr.*);
        }
        self.gopls_clients.deinit(gpa);
    }

    /// Looks up (or lazily spawns and initializes) the one `GoplsClient`
    /// for `module_root`. A spawn failure (e.g. `gopls` not installed --
    /// a real, expected case, not everyone using `.ntx` tooling has it on
    /// `PATH`) propagates as a real error; `handleHover` treats that as
    /// "no hover info available" rather than a server-fatal condition.
    fn getOrSpawnGoplsClient(self: *Server, gpa: std.mem.Allocator, io: Io, module_root: []const u8) !*GoplsClient {
        if (self.gopls_clients.get(module_root)) |client| return client;
        const client = try gpa.create(GoplsClient);
        errdefer gpa.destroy(client);
        client.* = .{};
        try client.spawn(io, gpa, module_root);
        errdefer client.deinit(gpa, io);
        const owned_root = try gpa.dupe(u8, module_root);
        errdefer gpa.free(owned_root);
        try self.gopls_clients.put(gpa, owned_root, client);
        return client;
    }

    /// Parses one already-length-delimited JSON-RPC message body (see
    /// `Transport.readMessage`) and dispatches it. Never returns a Zig
    /// error for a malformed *message* (bad JSON, missing `method`,
    /// unknown method) -- those become real JSON-RPC error responses
    /// instead, exactly what a real client expects back; a Zig error here
    /// means allocation failure, nothing else.
    pub fn handleMessage(self: *Server, gpa: std.mem.Allocator, io: Io, body: []const u8) !HandleResult {
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
            return .{ .notification = try self.handleDidOpen(gpa, obj.get("params") orelse .null) };
        }
        if (std.mem.eql(u8, method, "textDocument/didChange")) {
            return .{ .notification = try self.handleDidChange(gpa, obj.get("params") orelse .null) };
        }
        if (std.mem.eql(u8, method, "textDocument/didClose")) {
            return .{ .notification = try self.handleDidClose(gpa, obj.get("params") orelse .null) };
        }
        if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            return .{ .response = try self.handleSemanticTokensFull(gpa, id, obj.get("params") orelse .null) };
        }
        if (std.mem.eql(u8, method, "textDocument/hover")) {
            return .{ .response = try self.handleHover(gpa, io, id, obj.get("params") orelse .null) };
        }

        if (!is_request) return .{}; // unknown notification: ignore per spec
        return .{ .response = try encodeError(gpa, id, .method_not_found, "method not found") };
    }

    fn handleDidOpen(self: *Server, gpa: std.mem.Allocator, params: std.json.Value) !?[]u8 {
        const uri = textDocumentField(params, "uri") orelse return null;
        const text = textDocumentField(params, "text") orelse return null;
        try self.storeDocument(gpa, uri, text);
        return try publishDiagnosticsFor(gpa, uri, text);
    }

    /// Full-sync mode only (`ServerCapabilities.textDocumentSync = 1`) --
    /// `contentChanges`'s *last* entry always carries the document's
    /// entire current text, not an incremental edit.
    fn handleDidChange(self: *Server, gpa: std.mem.Allocator, params: std.json.Value) !?[]u8 {
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
        try self.storeDocument(gpa, uri, text);
        return try publishDiagnosticsFor(gpa, uri, text);
    }

    /// Publishes an empty diagnostics list for the closed document -- a
    /// document that's no longer open can't still have live errors shown
    /// against it in the editor.
    fn handleDidClose(self: *Server, gpa: std.mem.Allocator, params: std.json.Value) !?[]u8 {
        const uri = textDocumentField(params, "uri") orelse return null;
        self.removeDocument(gpa, uri);
        return try encodePublishDiagnostics(gpa, uri, &.{});
    }

    fn handleSemanticTokensFull(self: *Server, gpa: std.mem.Allocator, id: std.json.Value, params: std.json.Value) ![]u8 {
        const uri = textDocumentField(params, "uri") orelse "";
        const text = self.documents.get(uri) orelse "";
        const data = try SemanticTokens.compute(gpa, text);
        defer gpa.free(data);
        const Result = struct { data: []const u32 };
        return try encodeResult(gpa, Result, id, .{ .data = data });
    }

    /// `.ntx` LSP Stage 5: the real Volar-style forwarding this stage
    /// exists to prove. Every failure mode along the way (document not
    /// open, source doesn't currently transpile, no `SourceMapping`
    /// recorded at the exact requested position -- an accepted, honest
    /// scope limit given `PositionMap.ntxToGenerated`'s own exact-point-
    /// match design; not every `.ntx` token has a recorded mapping yet,
    /// `gopls` missing from `PATH`, `gopls` itself returning nothing for
    /// this position) degrades to a real `null` hover result, never a
    /// JSON-RPC error -- exactly what a real editor expects when there's
    /// simply nothing to show at a given position.
    fn handleHover(self: *Server, gpa: std.mem.Allocator, io: Io, id: std.json.Value, params: std.json.Value) ![]u8 {
        const uri = textDocumentField(params, "uri") orelse return try encodeNullResult(gpa, id);
        const pos = parsePositionParam(params) orelse return try encodeNullResult(gpa, id);
        const text = self.documents.get(uri) orelse return try encodeNullResult(gpa, id);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const found = Expose.findComposers(arena, text) catch return try encodeNullResult(gpa, id);
        if (found.err != null) return try encodeNullResult(gpa, id);
        const transpiled = Codegen.generateGo(arena, "main", text, found.composers, &.{}, found.uses, found.uses_start, found.uses_end, .{}) catch return try encodeNullResult(gpa, id);
        if (transpiled.err != null) return try encodeNullResult(gpa, id);
        const output = transpiled.output.?;

        // LSP positions are 0-based; every `Parser`/`Codegen` position is
        // 1-based -- the same `+1` `publishDiagnosticsFor` applies in the
        // opposite direction.
        const ntx_line = pos.line + 1;
        const ntx_col = pos.character + 1;
        const mapped = PositionMap.ntxToGenerated(output.source_map, ntx_line, ntx_col) orelse return try encodeNullResult(gpa, id);
        const gen_pos = PositionMap.offsetToPosition(output.generated, mapped.start);

        const ntx_path = GoplsClientModule.uriToPath(uri) orelse return try encodeNullResult(gpa, id);
        const ntx_dir = std.fs.path.dirname(ntx_path) orelse return try encodeNullResult(gpa, id);
        const module_root = GoplsClientModule.findModuleRoot(gpa, io, ntx_dir) catch return try encodeNullResult(gpa, id);
        defer gpa.free(module_root);

        const client = self.getOrSpawnGoplsClient(gpa, io, module_root) catch return try encodeNullResult(gpa, id);
        const generated_uri = (GoplsClientModule.derivedGeneratedUri(gpa, uri) catch return try encodeNullResult(gpa, id)) orelse return try encodeNullResult(gpa, id);
        defer gpa.free(generated_uri);

        client.syncDocument(gpa, generated_uri, output.generated) catch return try encodeNullResult(gpa, id);
        const hover_result = client.hover(gpa, arena, generated_uri, gen_pos.line, gen_pos.character) catch return try encodeNullResult(gpa, id);
        const h = hover_result orelse return try encodeNullResult(gpa, id);

        // The real `.ntx`-side span of the hovered token is already fully
        // known from the mapping itself (`mapped.ntx_col`/`mapped.ntx_len`)
        // -- deliberately *not* derived from `mapped.end - mapped.start`
        // (the generated-side span), which is a real, different length for
        // a `.string_literal`/`.style_token`/`.child_text` mapping: that
        // span includes the wrapping Go string quotes `writeGoStringLiteral`
        // adds, which the `.ntx`-side token never has. This is also
        // simpler and more correct than trying to reverse-map `gopls`'s
        // own returned range through `generatedToNtx` -- a real bug found
        // via this stage's own end-to-end smoke test: `generatedToNtx`
        // only ever resolves to a matching mapping's fixed *start*
        // position for any offset inside its span (that's what it's for --
        // "which token contains this offset," not "where exactly inside
        // this token"), so reverse-mapping a multi-byte range's *end* that
        // way collapsed it down to the same single-character span as the
        // start every time.
        const ntx_range = Protocol.Range{
            .start = .{ .line = ntx_line - 1, .character = mapped.ntx_col - 1 },
            .end = .{ .line = ntx_line - 1, .character = mapped.ntx_col - 1 + mapped.ntx_len },
        };
        return try encodeResult(gpa, Protocol.Hover, id, .{ .contents = .{ .value = h.contents_markdown }, .range = ntx_range });
    }

    /// Stores (or replaces) `uri`'s current text -- both `uri` and `text`
    /// are duped into `gpa`-owned memory, since the JSON-RPC message
    /// they're parsed from is freed by the caller right after
    /// `handleMessage` returns.
    fn storeDocument(self: *Server, gpa: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
        const owned_text = try gpa.dupe(u8, text);
        errdefer gpa.free(owned_text);
        if (self.documents.getPtr(uri)) |existing| {
            gpa.free(existing.*);
            existing.* = owned_text;
            return;
        }
        const owned_uri = try gpa.dupe(u8, uri);
        errdefer gpa.free(owned_uri);
        try self.documents.put(gpa, owned_uri, owned_text);
    }

    fn removeDocument(self: *Server, gpa: std.mem.Allocator, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value);
        }
    }

    /// The real stdio loop: read one framed message, dispatch it, write
    /// back whatever response (if any) resulted, repeat until `exit`.
    /// Every `Transport`/`handleMessage` error is real and fatal here --
    /// there's no meaningful way to recover mid-stream from a broken
    /// framing layer or an OOM, so `run` just surfaces the error to
    /// `main`, matching every other CLI entry point in this repo.
    pub fn run(self: *Server, gpa: std.mem.Allocator, io: Io, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        while (true) {
            const body = try Transport.readMessage(reader, gpa);
            defer gpa.free(body);

            const result = try self.handleMessage(gpa, io, body);
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
};

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

/// Reads `params.position.{line,character}` as a real, non-negative 0-based
/// LSP position -- `null` for any malformed shape, matching
/// `textDocumentField`'s own "malformed input means nothing to do" posture.
fn parsePositionParam(params: std.json.Value) ?struct { line: u32, character: u32 } {
    const position = switch (params) {
        .object => |o| o.get("position") orelse return null,
        else => return null,
    };
    const pos_obj = switch (position) {
        .object => |o| o,
        else => return null,
    };
    const line = switch (pos_obj.get("line") orelse return null) {
        .integer => |n| n,
        else => return null,
    };
    const character = switch (pos_obj.get("character") orelse return null) {
        .integer => |n| n,
        else => return null,
    };
    if (line < 0 or character < 0) return null;
    return .{ .line = @intCast(line), .character = @intCast(character) };
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

test "handleMessage: initialize returns a real result advertising full document sync" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const result = try server.handleMessage(std.testing.allocator, std.testing.io, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"type\",\"property\",\"string\"],\"tokenModifiers\":[]},\"full\":true},\"hoverProvider\":true}}}", result.response.?);
    try std.testing.expect(!result.should_exit);
}

test "handleMessage: initialize echoes back a real string id, not just a number one" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const result = try server.handleMessage(std.testing.allocator, std.testing.io, "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"initialize\",\"params\":{}}");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"type\",\"property\",\"string\"],\"tokenModifiers\":[]},\"full\":true},\"hoverProvider\":true}}}", result.response.?);
}

test "handleMessage: initialized notification produces no response and doesn't exit" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const result = try server.handleMessage(std.testing.allocator, std.testing.io, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    try std.testing.expect(result.response == null);
    try std.testing.expect(!result.should_exit);
}

test "handleMessage: shutdown responds with a real null result" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const result = try server.handleMessage(std.testing.allocator, std.testing.io, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}", result.response.?);
}

test "handleMessage: exit notification produces no response but does signal should_exit" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const result = try server.handleMessage(std.testing.allocator, std.testing.io, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    try std.testing.expect(result.response == null);
    try std.testing.expect(result.should_exit);
}

test "handleMessage: an unknown request method gets a real MethodNotFound error, not silence" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    // `textDocument/definition` -- still genuinely unimplemented as of
    // Stage 5 (`textDocument/hover` is implemented now, so it can no
    // longer stand in as "an unknown method" the way it used to).
    const result = try server.handleMessage(std.testing.allocator, std.testing.io, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/definition\",\"params\":{}}");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}", result.response.?);
}

test "handleMessage: an unknown notification (no id) is silently ignored, not errored" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const result = try server.handleMessage(std.testing.allocator, std.testing.io, "{\"jsonrpc\":\"2.0\",\"method\":\"$/someUnknownNotification\"}");
    try std.testing.expect(result.response == null);
    try std.testing.expect(!result.should_exit);
}

test "handleMessage: malformed JSON gets a real ParseError response with a null id" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const result = try server.handleMessage(std.testing.allocator, std.testing.io, "not json at all");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"request was not valid JSON\"}}", result.response.?);
}

test "handleMessage: a JSON value that isn't an object is a real InvalidRequest error" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const result = try server.handleMessage(std.testing.allocator, std.testing.io, "[1,2,3]");
    defer std.testing.allocator.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"JSON-RPC message must be an object\"}}", result.response.?);
}

test "run: a real initialize/initialized/shutdown/exit sequence produces exactly the two expected responses" {
    const gpa = std.testing.allocator;
    var server: Server = .{};
    defer server.deinit(gpa, std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var input = std.Io.Writer.Allocating.init(gpa);
    defer input.deinit();
    try Transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    try Transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    try Transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}");
    try Transport.writeMessage(&input.writer, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var reader = std.Io.Reader.fixed(input.writer.buffered());
    try server.run(gpa, std.testing.io, &reader, &aw.writer);

    const output = aw.writer.buffered();
    var out_reader = std.Io.Reader.fixed(output);
    const first = try Transport.readMessage(&out_reader, gpa);
    defer gpa.free(first);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"type\",\"property\",\"string\"],\"tokenModifiers\":[]},\"full\":true},\"hoverProvider\":true}}}", first);
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

fn encodeSemanticTokensFull(gpa: std.mem.Allocator, id: i64, uri: []const u8) ![]u8 {
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: i64,
        method: []const u8 = "textDocument/semanticTokens/full",
        params: struct { textDocument: struct { uri: []const u8 } },
    };
    return std.json.Stringify.valueAlloc(gpa, Msg{ .id = id, .params = .{ .textDocument = .{ .uri = uri } } }, .{});
}

test "handleMessage: didOpen with a clean .ntx document publishes empty diagnostics" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const gpa = std.testing.allocator;
    const body = try encodeDidOpen(gpa, "file:///test.go.ntx", clean_ntx_source);
    defer gpa.free(body);

    const result = try server.handleMessage(gpa, std.testing.io, body);
    try std.testing.expect(result.response == null);
    defer gpa.free(result.notification.?);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///test.go.ntx\",\"diagnostics\":[]}}",
        result.notification.?,
    );
}

test "handleMessage: didOpen with a broken .ntx document publishes a real diagnostic with a real position" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const gpa = std.testing.allocator;
    const body = try encodeDidOpen(gpa, "file:///test.go.ntx", broken_ntx_source);
    defer gpa.free(body);

    const result = try server.handleMessage(gpa, std.testing.io, body);
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
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const gpa = std.testing.allocator;

    const open_body = try encodeDidOpen(gpa, "file:///test.go.ntx", broken_ntx_source);
    defer gpa.free(open_body);
    const open_result = try server.handleMessage(gpa, std.testing.io, open_body);
    gpa.free(open_result.notification.?);

    const change_body = try encodeDidChange(gpa, "file:///test.go.ntx", clean_ntx_source);
    defer gpa.free(change_body);
    const change_result = try server.handleMessage(gpa, std.testing.io, change_body);
    defer gpa.free(change_result.notification.?);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///test.go.ntx\",\"diagnostics\":[]}}",
        change_result.notification.?,
    );
}

test "handleMessage: didClose publishes an empty diagnostics list for that document" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const gpa = std.testing.allocator;
    const body = try encodeDidClose(gpa, "file:///test.go.ntx");
    defer gpa.free(body);

    const result = try server.handleMessage(gpa, std.testing.io, body);
    defer gpa.free(result.notification.?);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///test.go.ntx\",\"diagnostics\":[]}}",
        result.notification.?,
    );
}

test "handleMessage: semanticTokens/full on a never-opened uri returns a real empty token array, not an error" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const gpa = std.testing.allocator;
    const body = try encodeSemanticTokensFull(gpa, 5, "file:///never-opened.go.ntx");
    defer gpa.free(body);

    const result = try server.handleMessage(gpa, std.testing.io, body);
    defer gpa.free(result.response.?);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"data\":[]}}", result.response.?);
}

test "handleMessage: semanticTokens/full on a real open document returns real delta-encoded tokens" {
    var server: Server = .{};
    defer server.deinit(std.testing.allocator, std.testing.io);
    const gpa = std.testing.allocator;

    const open_body = try encodeDidOpen(gpa, "file:///test.go.ntx", clean_ntx_source);
    defer gpa.free(open_body);
    const open_result = try server.handleMessage(gpa, std.testing.io, open_body);
    gpa.free(open_result.notification.?);

    const tokens_body = try encodeSemanticTokensFull(gpa, 7, "file:///test.go.ntx");
    defer gpa.free(tokens_body);
    const result = try server.handleMessage(gpa, std.testing.io, tokens_body);
    defer gpa.free(result.response.?);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, result.response.?, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 7), parsed.value.object.get("id").?.integer);
    const data = parsed.value.object.get("result").?.object.get("data").?.array;
    // `clean_ntx_source`'s only element is `<Container></Container>` --
    // its own opening AND closing tag each get a real .type token, 10
    // integers total.
    try std.testing.expectEqual(@as(usize, 10), data.items.len);
    try std.testing.expectEqual(@as(i64, 0), data.items[3].integer); // tokenType index for .type
    try std.testing.expectEqual(@as(i64, 0), data.items[8].integer); // tokenType index for .type (closing tag)
}
