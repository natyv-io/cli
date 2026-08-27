//! `.ntx` LSP Stage 5 (~/.claude/plans/lexical-wishing-penguin.md): a
//! minimal LSP *client* embedded in `ntx-lsp` itself, talking to a real
//! `gopls` child process over its own stdio -- the Volar-style "virtual
//! document" forwarding architecture this stage exists to prove. Reuses
//! `Transport.zig`'s existing `Content-Length` framing directly against
//! `gopls`'s own pipes (LSP's wire framing is identical in both
//! directions, so no new framing code is needed here).
//!
//! Real `gopls` behavior confirmed via a live protocol probe (a standalone
//! Python script driving the real `gopls` binary over real stdio against
//! this repo's own `examples/ntx-form/guest` fixture) *before* any of this
//! file was written, not assumed from documentation:
//! - After `initialize`/`initialized`, `gopls` sends unprompted
//!   `window/showMessage`/`window/logMessage`/
//!   `textDocument/publishDiagnostics` notifications while it loads the
//!   real Go package graph -- all safely discarded here, none block a
//!   real response from eventually arriving.
//! - A real `textDocument/hover` round-trips cleanly even against a URI
//!   that has never existed on disk (a genuine virtual/overlay document)
//!   as long as it's `didOpen`ed inside a directory `gopls` already
//!   recognizes as part of a loaded Go module -- confirming the one
//!   mechanism this whole stage depends on actually works.
//! - Using the exact same URI as an already-`natyv prepare`-generated
//!   `.natyv.go` file this virtual document is standing in for is
//!   necessary, not cosmetic: overlaying content at any *other* path
//!   produces real "duplicate declaration" diagnostics from `gopls`
//!   against the genuine file already on disk declaring the same Go
//!   symbols -- confirmed live before `derivedGeneratedUri` was written
//!   this way on purpose.
//! - No `client/registerCapability`/`workspace/configuration` request was
//!   observed from `gopls` in this basic flow, but `awaitResponse` answers
//!   any such request defensively anyway (a real, well-known minimal-LSP-
//!   client convention) so a `gopls` version that *does* send one can't
//!   leave the exchange hanging.
//!
//! `GoplsClient` is deliberately synchronous and single-request-at-a-time
//! (matching `Server.zig`'s own synchronous editor-facing dispatch loop):
//! sending a request blocks until that exact response arrives, discarding
//! or minimally answering anything else `gopls` sends in the meantime.
//! Real production LSP traffic can pipeline requests, but nothing in this
//! server's own architecture needs that yet.
//!
//! Self-referential-pointer safety: `reader`/`writer` are real
//! `std.Io.File.Reader`/`Writer` values whose own `buffer` field points at
//! this exact struct's `read_buf`/`write_buf` sibling fields. This is only
//! safe as long as a `GoplsClient` value never moves to a new address
//! after `spawn` populates those pointers -- every real construction site
//! in this codebase (`Server.zig`) allocates one via `gpa.create` and
//! always operates on it through a stable `*GoplsClient`, never by value,
//! for exactly this reason.

const std = @import("std");
const Io = std.Io;
const Transport = @import("Transport.zig");

pub const GoplsClient = struct {
    child: std.process.Child = undefined,
    read_buf: [16384]u8 = undefined,
    write_buf: [4096]u8 = undefined,
    reader: std.Io.File.Reader = undefined,
    writer: std.Io.File.Writer = undefined,
    next_id: i64 = 1,
    /// URI -> current LSP document version, for `syncDocument`'s own
    /// open-vs-change bookkeeping. Keys are owned (`allocator.dupe`d).
    opened: std.StringHashMapUnmanaged(i64) = .empty,

    /// Spawns a real `gopls` process rooted at `workspace_dir` and
    /// completes the real `initialize`/`initialized` handshake against it.
    /// Must be called on a `GoplsClient` already at its final, stable
    /// memory address (see this file's own doc comment) -- never on a
    /// value about to be returned or copied elsewhere.
    pub fn spawn(self: *GoplsClient, io: Io, allocator: std.mem.Allocator, workspace_dir: []const u8) !void {
        self.child = try std.process.spawn(io, .{
            .argv = &.{"gopls"},
            .cwd = .{ .path = workspace_dir },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer self.child.kill(io);
        self.reader = self.child.stdout.?.reader(io, &self.read_buf);
        self.writer = self.child.stdin.?.writer(io, &self.write_buf);
        self.next_id = 1;

        const root_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{workspace_dir});
        defer allocator.free(root_uri);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();

        const id = self.nextId();
        try self.sendRequest(allocator, id, "initialize", struct {
            processId: ?i64 = null,
            rootUri: []const u8,
            capabilities: struct {} = .{},
        }, .{ .rootUri = root_uri });
        _ = try self.awaitResponse(allocator, arena_state.allocator(), id);

        try self.sendNotification(allocator, "initialized", struct {}, .{});
    }

    /// Best-effort graceful `shutdown`/`exit`, then unconditionally kills
    /// (and, per `std.process.Child.kill`'s own doc, reaps) the child --
    /// safe to call even if the graceful path already made it exit on its
    /// own (`kill` is documented idempotent once `wait` has succeeded).
    /// This server's own process is always short-lived relative to an
    /// editor session, so a strict shutdown timeout isn't worth the extra
    /// complexity here.
    pub fn deinit(self: *GoplsClient, allocator: std.mem.Allocator, io: Io) void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const id = self.nextId();
        if (self.sendRequest(allocator, id, "shutdown", struct {}, .{})) |_| {
            _ = self.awaitResponse(allocator, arena_state.allocator(), id) catch {};
            self.sendNotification(allocator, "exit", struct {}, .{}) catch {};
        } else |_| {}
        self.child.kill(io);

        var it = self.opened.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.opened.deinit(allocator);
    }

    fn nextId(self: *GoplsClient) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn sendRequest(self: *GoplsClient, allocator: std.mem.Allocator, id: i64, method: []const u8, comptime Params: type, params: Params) !void {
        const Envelope = struct {
            jsonrpc: []const u8 = "2.0",
            id: i64,
            method: []const u8,
            params: Params,
        };
        const body = try std.json.Stringify.valueAlloc(allocator, Envelope{ .id = id, .method = method, .params = params }, .{});
        defer allocator.free(body);
        try Transport.writeMessage(&self.writer.interface, body);
    }

    fn sendNotification(self: *GoplsClient, allocator: std.mem.Allocator, method: []const u8, comptime Params: type, params: Params) !void {
        const Envelope = struct {
            jsonrpc: []const u8 = "2.0",
            method: []const u8,
            params: Params,
        };
        const body = try std.json.Stringify.valueAlloc(allocator, Envelope{ .method = method, .params = params }, .{});
        defer allocator.free(body);
        try Transport.writeMessage(&self.writer.interface, body);
    }

    fn sendRawResponse(self: *GoplsClient, allocator: std.mem.Allocator, id: std.json.Value, result: std.json.Value) !void {
        const Envelope = struct {
            jsonrpc: []const u8 = "2.0",
            id: std.json.Value,
            result: std.json.Value,
        };
        const body = try std.json.Stringify.valueAlloc(allocator, Envelope{ .id = id, .result = result }, .{});
        defer allocator.free(body);
        try Transport.writeMessage(&self.writer.interface, body);
    }

    /// Reads and discards notifications, and minimally answers any real
    /// request `gopls` sends, until the response to `id` itself arrives.
    /// `arena` owns the returned `std.json.Value`'s backing memory (freed
    /// by the caller's own arena, not `allocator`, matching this repo's
    /// existing `handleMessage`/`Diagnostics.compute` convention of
    /// arena-scoping parsed JSON).
    fn awaitResponse(self: *GoplsClient, allocator: std.mem.Allocator, arena: std.mem.Allocator, id: i64) !std.json.Value {
        while (true) {
            const body = try Transport.readMessage(&self.reader.interface, allocator);
            defer allocator.free(body);
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch continue;
            const obj = switch (value) {
                .object => |o| o,
                else => continue,
            };

            const msg_id = obj.get("id");
            const method = obj.get("method");

            if (msg_id != null and method == null) {
                const matches = switch (msg_id.?) {
                    .integer => |n| n == id,
                    else => false,
                };
                if (matches) return value;
                continue; // a response to some other, no-longer-awaited id
            }

            if (msg_id != null and method != null) {
                // A real request FROM gopls -- must be answered, or gopls
                // may block waiting for it (see this file's own doc
                // comment: not observed in the basic hover flow this
                // stage proves, but defensive regardless).
                try self.respondDefault(allocator, msg_id.?, method.?, obj.get("params"));
            }
            // else: a notification (no id) -- discard.
        }
    }

    fn respondDefault(self: *GoplsClient, allocator: std.mem.Allocator, id: std.json.Value, method: std.json.Value, params: ?std.json.Value) !void {
        const method_str = switch (method) {
            .string => |s| s,
            else => return,
        };
        if (std.mem.eql(u8, method_str, "workspace/configuration")) {
            const n: usize = blk: {
                const p = params orelse break :blk 0;
                const obj = switch (p) {
                    .object => |o| o,
                    else => break :blk 0,
                };
                const items = obj.get("items") orelse break :blk 0;
                break :blk switch (items) {
                    .array => |a| a.items.len,
                    else => 0,
                };
            };
            var arr: std.json.Array = .init(allocator);
            defer arr.deinit();
            for (0..n) |_| try arr.append(.null);
            try self.sendRawResponse(allocator, id, .{ .array = arr });
            return;
        }
        try self.sendRawResponse(allocator, id, .null);
    }

    /// Overlays `text` at `uri` as `gopls`'s own current document content
    /// for the *first* time -- the real, low-level `textDocument/didOpen`
    /// notification. Real callers touching a URI more than once (every
    /// real caller in this codebase) should use `syncDocument` instead,
    /// which tracks per-URI open state and sends a real `didChange` on
    /// every call after the first -- sending two `didOpen`s for the same
    /// URI with no `didClose` between them is a real LSP protocol
    /// violation, even though `gopls` happens to tolerate it in practice.
    /// Exposed as its own function (rather than folded entirely into
    /// `syncDocument`) so a caller that already knows a URI is genuinely
    /// new doesn't need to touch `opened` bookkeeping at all -- used
    /// directly by this file's own tests, which only ever open one URI
    /// once each.
    pub fn didOpen(self: *GoplsClient, allocator: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
        try self.sendNotification(allocator, "textDocument/didOpen", struct {
            textDocument: struct {
                uri: []const u8,
                languageId: []const u8 = "go",
                version: i64 = 1,
                text: []const u8,
            },
        }, .{ .textDocument = .{ .uri = uri, .text = text } });
    }

    /// The real per-`hover`-request entry point: `didOpen`s `uri` the
    /// first time it's seen, `didChange`s it (with a real, incrementing
    /// `version`) every time after -- correct full-sync behavior matching
    /// this server's own editor-facing `textDocumentSync = 1`, since a
    /// virtual document's own generated content genuinely changes on
    /// every real edit to its source `.ntx` file.
    pub fn syncDocument(self: *GoplsClient, allocator: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
        if (self.opened.getPtr(uri)) |version| {
            version.* += 1;
            try self.sendNotification(allocator, "textDocument/didChange", struct {
                textDocument: struct { uri: []const u8, version: i64 },
                contentChanges: []const struct { text: []const u8 },
            }, .{ .textDocument = .{ .uri = uri, .version = version.* }, .contentChanges = &.{.{ .text = text }} });
            return;
        }
        try self.didOpen(allocator, uri, text);
        const owned_uri = try allocator.dupe(u8, uri);
        errdefer allocator.free(owned_uri);
        try self.opened.put(allocator, owned_uri, 1);
    }

    pub const HoverPosition = struct { line: u32, character: u32 };
    pub const HoverRange = struct { start: HoverPosition, end: HoverPosition };

    pub const HoverResult = struct {
        contents_markdown: []const u8,
        /// 0-based LSP line/character, exactly as `gopls` returned them --
        /// `null` when `gopls`'s own response carried no `range` at all
        /// (allowed by the real LSP spec; the caller then has no
        /// generated-side span to map back to a `.ntx` position with).
        range: ?HoverRange,
    };

    /// Forwards a real `textDocument/hover` to `gopls` for `uri` at the
    /// given 0-based `line`/`character` -- both already in *generated*-
    /// document terms; mapping a real `.ntx` position to/from this shape
    /// is the caller's job (`Server.zig`, via `PositionMap` +
    /// `PositionMap.offsetToPosition`/`positionToOffset`), not this
    /// file's -- this file only ever speaks the real gopls wire protocol.
    /// Returns `null` for a real "nothing to show here" response (`gopls`
    /// returns a bare JSON `null` result for that, not an error).
    pub fn hover(self: *GoplsClient, allocator: std.mem.Allocator, arena: std.mem.Allocator, uri: []const u8, line: u32, character: u32) !?HoverResult {
        const id = self.nextId();
        try self.sendRequest(allocator, id, "textDocument/hover", struct {
            textDocument: struct { uri: []const u8 },
            position: struct { line: u32, character: u32 },
        }, .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } });

        const response = try self.awaitResponse(allocator, arena, id);
        const obj = switch (response) {
            .object => |o| o,
            else => return null,
        };
        const result = obj.get("result") orelse return null;
        if (result == .null) return null;
        const robj = switch (result) {
            .object => |o| o,
            else => return null,
        };

        const contents = robj.get("contents") orelse return null;
        const markdown = extractContentsValue(contents) orelse return null;

        var range: ?HoverRange = null;
        if (robj.get("range")) |r| range = parseRange(r);

        return .{ .contents_markdown = markdown, .range = range };
    }

    /// `hover`'s real `contents` field is a real LSP union
    /// (`MarkupContent | MarkedString | MarkedString[]`) -- `gopls` always
    /// sends `MarkupContent{kind, value}` in practice (confirmed via the
    /// live protocol probe), so only that shape plus a bare string
    /// fallback are handled; anything else yields `null` rather than a
    /// guess.
    fn extractContentsValue(contents: std.json.Value) ?[]const u8 {
        return switch (contents) {
            .string => |s| s,
            .object => |o| switch (o.get("value") orelse return null) {
                .string => |s| s,
                else => null,
            },
            else => null,
        };
    }

    fn parseRange(r: std.json.Value) ?HoverRange {
        const obj = switch (r) {
            .object => |o| o,
            else => return null,
        };
        const start = parsePosition(obj.get("start") orelse return null) orelse return null;
        const end = parsePosition(obj.get("end") orelse return null) orelse return null;
        return .{ .start = start, .end = end };
    }

    fn parsePosition(p: std.json.Value) ?HoverPosition {
        const obj = switch (p) {
            .object => |o| o,
            else => return null,
        };
        const line = switch (obj.get("line") orelse return null) {
            .integer => |n| n,
            else => return null,
        };
        const character = switch (obj.get("character") orelse return null) {
            .integer => |n| n,
            else => return null,
        };
        if (line < 0 or character < 0) return null;
        return .{ .line = @intCast(line), .character = @intCast(character) };
    }
};

/// Walks up from `start_dir` looking for a real `go.mod`, returning the
/// first directory that has one -- the real Go module root `gopls` should
/// be rooted at, matching the plan's own "per open `.ntx` document's
/// containing Go module" design. Falls back to `start_dir` itself if no
/// `go.mod` is found anywhere above it (an `.ntx` file outside any real Go
/// module is a real, if unusual, input `gopls` itself is left to reject
/// -- not pre-validated here). Returns memory owned by `allocator`.
pub fn findModuleRoot(allocator: std.mem.Allocator, io: Io, start_dir: []const u8) ![]u8 {
    var dir: []const u8 = start_dir;
    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ dir, "go.mod" });
        defer allocator.free(candidate);
        if (Io.Dir.accessAbsolute(io, candidate, .{})) |_| {
            return try allocator.dupe(u8, dir);
        } else |_| {}
        const parent = std.fs.path.dirname(dir) orelse return try allocator.dupe(u8, start_dir);
        dir = parent;
    }
}

/// Strips a `file://` URI down to its plain filesystem path -- matches
/// `Server.zig`'s own existing "treat URIs as plain strings, no percent-
/// decoding" convention (a real editor never percent-encodes a plain
/// local path on POSIX in practice). `null` for any URI not using the
/// `file://` scheme.
pub fn uriToPath(uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    return uri[prefix.len..];
}

/// Derives the real generated-Go URI for a given `.ntx` file's own URI,
/// using the identical `<stem>.natyv.go` naming rule `src/cli/Prepare.zig`
/// already uses for real -- so `gopls`'s overlay for this URI supersedes
/// whatever `natyv prepare` last wrote there instead of colliding with it
/// as a second, differently-named file declaring the same Go symbols (a
/// real, live-confirmed problem -- see this file's own top doc comment).
/// `null` if `ntx_uri` doesn't end in the expected `.go.ntx` shape.
pub fn derivedGeneratedUri(allocator: std.mem.Allocator, ntx_uri: []const u8) !?[]u8 {
    if (!std.mem.endsWith(u8, ntx_uri, ".ntx")) return null;
    const without_ntx = ntx_uri[0 .. ntx_uri.len - ".ntx".len];
    if (!std.mem.endsWith(u8, without_ntx, ".go")) return null;
    const stem = without_ntx[0 .. without_ntx.len - ".go".len];
    return try std.fmt.allocPrint(allocator, "{s}.natyv.go", .{stem});
}

test "derivedGeneratedUri: a real .go.ntx URI derives its own real .natyv.go sibling" {
    const uri = try derivedGeneratedUri(std.testing.allocator, "file:///a/b/form.go.ntx");
    defer std.testing.allocator.free(uri.?);
    try std.testing.expectEqualStrings("file:///a/b/form.natyv.go", uri.?);
}

test "derivedGeneratedUri: anything not ending in .go.ntx is a clean null, not a guess" {
    try std.testing.expect(try derivedGeneratedUri(std.testing.allocator, "file:///a/b/form.ntx") == null);
    try std.testing.expect(try derivedGeneratedUri(std.testing.allocator, "file:///a/b/form.rs.ntx") == null);
    try std.testing.expect(try derivedGeneratedUri(std.testing.allocator, "file:///a/b/plain.go") == null);
}

test "uriToPath: strips the file:// scheme, leaving the plain path" {
    try std.testing.expectEqualStrings("/a/b/c.go", uriToPath("file:///a/b/c.go").?);
    try std.testing.expect(uriToPath("not-a-file-uri") == null);
}

/// This Zig version's `Io.Dir` has no `realpathAlloc` convenience (unlike
/// several other `*Alloc` real-path functions it does have) -- just the
/// buffer-writing `realPath`, wrapped here the same way those other
/// functions wrap it internally.
fn realPathAlloc(dir: Io.Dir, io: Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

test "findModuleRoot: finds a go.mod several directories above the start point" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module roottest\n\ngo 1.23\n" });
    var sub = try tmp.dir.createDirPathOpen(io, "guest/components", .{});
    defer sub.close(io);

    const tmp_abs = try realPathAlloc(tmp.dir, io, std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);
    const start = try std.fs.path.join(std.testing.allocator, &.{ tmp_abs, "guest", "components" });
    defer std.testing.allocator.free(start);

    const root = try findModuleRoot(std.testing.allocator, io, start);
    defer std.testing.allocator.free(root);
    try std.testing.expectEqualStrings(tmp_abs, root);
}

test "findModuleRoot: falls back to the start directory itself when no go.mod exists anywhere above it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const tmp_abs = try realPathAlloc(tmp.dir, io, std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs);

    const root = try findModuleRoot(std.testing.allocator, io, tmp_abs);
    defer std.testing.allocator.free(root);
    try std.testing.expectEqualStrings(tmp_abs, root);
}

// Real, live integration tests against the real, checked-in
// `examples/ntx-form/guest` fixture -- matching this project's own
// established "don't mock a real subprocess dependency" discipline
// (`Validate.zig`'s own `go list` tests, `Compile.zig`'s real `tinygo`
// spawns). Requires a real `gopls` on `PATH`, same as those require a
// real `go`/`tinygo` -- no skip-if-missing logic, matching this
// codebase's existing stance that the dev environment has the tools it
// needs.
const guest_dir = "examples/ntx-form/guest";

test "GoplsClient: a real spawn+initialize handshake against the real ntx-form fixture succeeds" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const abs_guest_dir = try std.fs.path.join(allocator, &.{ cwd_path, guest_dir });
    defer allocator.free(abs_guest_dir);

    var client: GoplsClient = .{};
    try client.spawn(io, allocator, abs_guest_dir);
    defer client.deinit(allocator, io);
}

test "GoplsClient: a real hover against a virtual, never-on-disk generated document returns gopls's real real type info" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const abs_guest_dir = try std.fs.path.join(allocator, &.{ cwd_path, guest_dir });
    defer allocator.free(abs_guest_dir);

    var client: GoplsClient = .{};
    try client.spawn(io, allocator, abs_guest_dir);
    defer client.deinit(allocator, io);

    // A URI that never touches disk, matching Stage 5's real production
    // shape (`Output.generated`, transpiled in-process, never written) --
    // deliberately distinct from the real on-disk `form.natyv.go` this
    // fixture's own `natyv prepare` output already sits at, so this test
    // also proves the never-on-disk case specifically, not just the
    // simpler "overlay an existing file" case.
    const virtual_uri = try std.fmt.allocPrint(allocator, "file://{s}/form.go.ntx.generated.go", .{abs_guest_dir});
    defer allocator.free(virtual_uri);

    const dir = try Io.Dir.cwd().openDir(io, guest_dir, .{});
    const content = try dir.readFileAlloc(io, "form.natyv.go", allocator, .unlimited);
    defer allocator.free(content);

    try client.didOpen(allocator, virtual_uri, content);

    // Real position of "handleSave" inside "Button3.OnClick(handleSave)"
    // -- computed the same way `Server.zig`'s own hover handler will, via
    // `Codegen.PositionMap.offsetToPosition` over the exact substring
    // index (`Codegen` re-exports `PositionMap` -- see `Codegen.zig`'s own
    // doc comment on that re-export for why it isn't a separate named
    // module of its own).
    const Codegen = @import("Codegen");
    const idx = std.mem.indexOf(u8, content, "handleSave").?;
    const pos = Codegen.PositionMap.offsetToPosition(content, idx);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const result = (try client.hover(allocator, arena_state.allocator(), virtual_uri, pos.line, pos.character)).?;
    try std.testing.expect(std.mem.indexOf(u8, result.contents_markdown, "func handleSave() error") != null);
    try std.testing.expect(result.range != null);
}
