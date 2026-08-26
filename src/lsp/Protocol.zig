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

/// Deliberately empty for Stage 1 -- no real language feature is wired up
/// yet. `textDocumentSync`/`hoverProvider`/etc. get added as fields here
/// only once each corresponding stage actually lands (Stage 2: diagnostics
/// needs `textDocumentSync`; Stage 4: `hoverProvider`/`definitionProvider`)
/// -- advertising a capability before the handler exists would be a real
/// client-visible lie, not just premature.
pub const ServerCapabilities = struct {};

pub const InitializeResult = struct {
    capabilities: ServerCapabilities = .{},
};
