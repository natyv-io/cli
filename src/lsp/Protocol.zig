//! Real LSP JSON-RPC shapes, Stage 1 scope only (lifecycle messages --
//! `initialize`/`initialized`/`shutdown`/`exit` -- plus the generic
//! error-response shape every later stage's request handling will reuse).
//! `id`/`params`/`result` are inherently polymorphic per the JSON-RPC spec
//! (an id is a string, number, or absent; params/result shapes vary by
//! method) -- kept as `std.json.Value` here rather than forced into a
//! narrower Zig type, matching `std.json.Value`'s own real support for
//! being embedded directly inside a typed struct's field (its
//! `jsonStringify`/parse-time handling round-trips whatever JSON shape was
//! actually there). Concrete shapes this server itself controls
//! end-to-end (e.g. `InitializeResult`) are real Zig structs instead.

const std = @import("std");

pub const version = "2.0";

pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
};

pub const ResponseError = struct {
    code: i32,
    message: []const u8,
};

/// `textDocumentSync = 1` (Full) as of Stage 2 -- real diagnostics need
/// the client to send the document's current full text on every change,
/// which `TextDocumentSyncKind.Full` (value `1`) is what asks for.
/// `hoverProvider`/`definitionProvider`/etc. get added as fields here only
/// once each corresponding stage actually lands (Stage 4) -- advertising a
/// capability before the handler exists would be a real client-visible
/// lie, not just premature.
pub const ServerCapabilities = struct {
    textDocumentSync: u32 = 1,
};

pub const InitializeResult = struct {
    capabilities: ServerCapabilities = .{},
};

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

/// Zero-width (`start == end`) for every diagnostic today -- `Expose`'s
/// and `Codegen`'s own error types only ever carry a single point
/// position, not a span, so a zero-width range is the honest
/// representation, not an approximation of a real range this server
/// doesn't actually have.
pub const Diagnostic = struct {
    range: Range,
    message: []const u8,
};

pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    diagnostics: []const Diagnostic,
};
