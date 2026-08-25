//! `natyv bind`'s text-emission layer -- generalized in Stage 2.1 of
//! ~/.claude/plans/lexical-wishing-penguin.md away from Stage 1's
//! hardcoded fixture naming. Consumes `Reflect.zig`'s `FnDescriptor`s plus
//! a caller-supplied `library` name and `header` path (from a real
//! `bindings` config entry, once `Bind.zig` exists) and emits (a) a Zig
//! host-trampoline source per function,
//! matching `src/widgets/WidgetHostFunctions.zig`'s real established shape
//! (`callconv(.c) void`, exactly 1 input + 1 output `ExtismVal`, JSON
//! request/response via `host_fn_util.readGuestBytes`/`writeGuestBytes`/
//! `writeErrorJson`), and (b) a Go guest-wrapper source per function,
//! matching `sdk/go/widgets/internal/value.go`'s real established shape
//! (`//go:wasmimport extism:host/user <name>` on `func(uint64) uint64`,
//! `pdk.ResultBytes`/`ParamBytes`). Text emission only -- no compiler
//! invocation happens here (that's what this stage's own tests do,
//! separately, against the emitted output).
//!
//! **Generic path** covers any function whose params are only
//! `int_primitive`/`float_primitive`/`opaque_handle`/`byte_buffer_in`/
//! `byte_buffer_out`/`length_ptr_inout`, with at most one `struct_out_ptr`
//! param, and whose return is
//! `void_kind`/`int_primitive`/`float_primitive`/`opaque_handle` --
//! `fixture_create`/`fixture_destroy`/`fixture_get_point` all go through
//! this path unmodified, and it generalizes to real zlib functions
//! (Stage 2.9's own `crc32`, Stage 2.10's own `compress`/`uncompress`)
//! without new per-function code. Every non-out-param becomes a
//! positional JSON request field (`p0`, `p1`, ... -- C's type system
//! doesn't preserve parameter names, so this is a real, accepted
//! limitation, not an oversight); an `opaque_handle` param is actually a
//! `u32` id resolved through `HandleTable.zig`, never a raw pointer
//! crossing the wire; a `struct_out_ptr` param's fields are flattened
//! directly into the response object; an `opaque_handle` return becomes a
//! new id inserted into the same table (`"handle"` response field), a
//! primitive return becomes a `"result"` field. `int_primitive`
//! params/returns carry their own real C width/signedness (Stage 2.9 --
//! `zlibCompileFlags`-style trivial functions happened to make `i32`/
//! `int32` look like a universal default, but real ones like `uLong`
//! aren't) rather than always assuming `i32`/`int32`. A `byte_buffer_in`
//! param (Stage 2.9 -- a `const <byte> *`, always paired with an
//! immediately-following length param) becomes one base64-encoded string
//! request field; the length param itself is dropped from the guest-
//! facing surface entirely, since the host derives it from the real
//! decoded byte count instead (Go's own `[]byte` <-> JSON already
//! base64-encodes automatically, so the guest side needs no special
//! handling at all -- only the host side runs a real `std.base64` decode).
//! A `byte_buffer_out` param (Stage 2.10 -- a *non-const* `<byte> *`,
//! e.g. `compress`'s own `dest`, always paired with an immediately-
//! following `length_ptr_inout`, e.g. `destLen`) is the mirror image: the
//! guest supplies only a plain int *capacity* request field (the buffer
//! itself is entirely host-allocated and never crosses the wire inbound
//! at all), and gets back one base64-encoded response field holding
//! exactly the real bytes the call wrote (sized by the real post-call
//! length, which may be less than the requested capacity) -- alongside
//! the function's normal `"result"`/struct-field response data, not
//! instead of it.
//!
//! **A function name containing "destroy" additionally removes its first
//! `opaque_handle` argument from the handle table after a successful
//! call** -- the fixture's own `fixture_destroy` needs this and there's no
//! way to infer "this call invalidates the handle" from the C type system
//! alone, so a naming convention stands in, same spirit as this project's
//! own existing `on[A-Z]` -> `.OnXxx()` event-attribute convention in
//! `ntx/Codegen.zig`.
//!
//! **Callback path** is a dedicated, hand-modeled emission for exactly the
//! `fixture_set_callback`/`fixture_trigger` pair -- not a generic solution
//! for arbitrary callback shapes (confirmed out of scope for Stage 1, see
//! the plan file). A real C function pointer can't cross the wasm
//! boundary, so `fixtureSetCallbackHostFn` registers one real, static,
//! host-side `callconv(.c)` function with the C library (passing the
//! handle id itself as `user_data`, since natyv can't allocate any richer
//! context the real C library would round-trip back); when the library
//! later calls it, the invocation is recorded into a small fixed buffer a
//! test can observe -- proving the real native registration/invocation
//! round trip compiles and works, without yet wiring delivery across the
//! wasm boundary via `natyv_dispatch` (that's Stage 2's job). The Go side
//! still generates a real local closure-registration map (mirrors
//! `sdk/go/widgets/internal/dispatch.go`'s own handler-table shape) even
//! though nothing calls into it yet.
const std = @import("std");
const Reflect = @import("Reflect.zig");

/// `generate`/`emitGeneric`/`emitCallbackPair` build their output through a
/// large number of small intermediate `allocPrint`/`ArrayList` allocations
/// they never individually free -- callers are expected to pass an arena
/// allocator and free everything at once, the same convention
/// `src/cli/Prepare.zig` already established for `.ntx` codegen (see
/// `src/cli/main.zig`'s `.prepare`/`.build` cases, both arena-wrapped).
pub const GenError = error{UnsupportedShape} || std.mem.Allocator.Error;

/// One real Extism-registered host function this `generate` call produced
/// -- `extism_name` is the exact string a guest's `//go:wasmimport`
/// declares and `extism_function_new`'s own first arg must match;
/// `zig_fn_name` is the real `pub fn ...HostFn` in the emitted Zig source.
/// Stage 2.2's own `src/cli/Bind.zig` needs this to build a real
/// `c.extism_function_new(info.extism_name, ..., <library>.<info.zig_fn_name>,
/// ...)` registration call per function without re-parsing generated Zig
/// source text back into structured data.
pub const HostFunctionInfo = struct {
    extism_name: []const u8,
    zig_fn_name: []const u8,
};

pub const Output = struct {
    zig_source: []const u8,
    go_source: []const u8,
    host_functions: []const HostFunctionInfo,
};

fn pascalCase(allocator: std.mem.Allocator, snake: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var capitalize_next = true;
    for (snake) |ch| {
        if (ch == '_') {
            capitalize_next = true;
            continue;
        }
        if (capitalize_next) {
            try out.append(allocator, std.ascii.toUpper(ch));
            capitalize_next = false;
        } else {
            try out.append(allocator, ch);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn camelCase(allocator: std.mem.Allocator, snake: []const u8) ![]u8 {
    const pascal = try pascalCase(allocator, snake);
    if (pascal.len > 0) pascal[0] = std.ascii.toLower(pascal[0]);
    return pascal;
}

/// Stage 2.9: real C integers aren't all `i32` -- zlib's own `uLong`/
/// `uInt` are 64-bit/32-bit *unsigned* on this platform, and a `crc32`-
/// shaped function silently mis-marshals (or simply fails to compile,
/// since Zig has no implicit narrowing) if its wire type doesn't match.
/// Only two real buckets exist among every C integer width this codebase
/// has actually reflected so far (16/32-bit and 64-bit) -- narrower than
/// 32 bits (e.g. a real `short`) still gets the 32-bit wire type, a
/// harmless widening, not a correctness gap.
fn zigIntType(bits: u16, signed: bool) []const u8 {
    if (signed) return if (bits > 32) "i64" else "i32";
    return if (bits > 32) "u64" else "u32";
}

fn goIntType(bits: u16, signed: bool) []const u8 {
    if (signed) return if (bits > 32) "int64" else "int32";
    return if (bits > 32) "uint64" else "uint32";
}

/// The real wire-facing field type for a request/response param, on each
/// side -- dispatches across every kind `emitGeneric`'s generic path
/// supports (`opaque_handle`/`byte_buffer_in` need their own fixed types;
/// `int_primitive`/`float_primitive` need `p`'s own real width/
/// signedness, not a blind `i32`/`int32`). `p.kind` must not be
/// `.struct_out_ptr`/`.callback_ptr`/`.userdata_ptr` -- those never
/// become a plain request/response field the way the others do.
fn zigFieldType(p: Reflect.Param) []const u8 {
    return switch (p.kind) {
        .opaque_handle => "u32",
        .byte_buffer_in => "[]const u8",
        // Stage 2.10: on the wire, a `.length_ptr_inout` is always the
        // guest-supplied *capacity* value for its paired `.byte_buffer_out`
        // -- a plain int field, using its own real pointee width/
        // signedness exactly like `.int_primitive` does.
        .int_primitive, .length_ptr_inout => zigIntType(p.int_bits, p.int_signed),
        .float_primitive => "f32",
        else => unreachable,
    };
}

fn goFieldType(p: Reflect.Param) []const u8 {
    return switch (p.kind) {
        .opaque_handle => "uint32",
        .byte_buffer_in => "[]byte",
        .int_primitive, .length_ptr_inout => goIntType(p.int_bits, p.int_signed),
        .float_primitive => "float32",
        else => unreachable,
    };
}

/// A non-out-param's request-field role -- separated from `Reflect.Param`
/// so the emitter doesn't need to re-derive "which index is this in the
/// request struct" (out-params don't get one) in three different places.
/// Carries the full `Reflect.Param` (not just its `kind`) since
/// `zigFieldType`/`goFieldType` need `int_bits`/`int_signed` too now.
const ReqField = struct {
    index: usize,
    param: Reflect.Param,
};

/// Also `emitGeneric`'s single source of shape validation -- any param
/// kind not recognized below is a real `error.UnsupportedShape`, so the
/// separate blanket check this function used to require alongside it
/// (`if (out_param == null) for (...) ...`) was fully redundant and has
/// been removed.
///
/// **A `.byte_buffer_in` param must be immediately followed by an
/// `.int_primitive` length param** -- natyv has no other way to know how
/// many bytes to read (real C convention: zlib's own `crc32(uLong, const
/// Bytef *buf, uInt len)` is exactly this shape). The pair is emitted as
/// *one* request field (the buffer's own real decoded length becomes the
/// length argument at call time, see `emitGeneric`'s own call-building
/// loop) -- the length param itself never gets its own separate request
/// field or guest-facing Go parameter, which is both simpler and more
/// idiomatic (a Go caller passes one `[]byte`, never a redundant
/// buffer+length pair).
fn collectReqFields(allocator: std.mem.Allocator, params: []const Reflect.Param) ![]ReqField {
    var fields: std.ArrayList(ReqField) = .empty;
    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const p = params[i];
        switch (p.kind) {
            .int_primitive, .float_primitive, .opaque_handle => try fields.append(allocator, .{ .index = i, .param = p }),
            .byte_buffer_in => {
                if (i + 1 >= params.len or params[i + 1].kind != .int_primitive) return error.UnsupportedShape;
                try fields.append(allocator, .{ .index = i, .param = p });
                i += 1; // the paired length param is consumed here, not its own field
            },
            // Stage 2.10: `.byte_buffer_out` (e.g. zlib's own `Bytef
            // *dest`) must be immediately followed by a `.length_ptr_inout`
            // param (its own real capacity/actual-length pointer -- real
            // C convention, no other shape zlib or any similar library
            // uses). Unlike `.byte_buffer_in`'s pairing, the request
            // field here represents the *length* param, not the buffer --
            // the buffer itself is never guest-supplied at all (it's a
            // pure out-param, entirely host-allocated), only its real
            // capacity is, as a plain int value.
            .byte_buffer_out => {
                if (i + 1 >= params.len or params[i + 1].kind != .length_ptr_inout) return error.UnsupportedShape;
                try fields.append(allocator, .{ .index = i + 1, .param = params[i + 1] });
                i += 1; // the paired length_ptr_inout param is consumed here
            },
            .struct_out_ptr => {},
            else => return error.UnsupportedShape,
        }
    }
    return fields.toOwnedSlice(allocator);
}

fn findStructOutParam(params: []const Reflect.Param) ?struct { index: usize, param: Reflect.Param } {
    for (params, 0..) |p, i| {
        if (p.kind == .struct_out_ptr) return .{ .index = i, .param = p };
    }
    return null;
}

/// Emits one function's Zig host trampoline + Go wrapper via the generic
/// path described in this file's own doc comment. `is_destroy` triggers
/// the handle-table-removal convention. `c_alias`/`handle_table_name` are
/// this entry's own per-library names (see `generate`'s own doc comment
/// on why these can't just be hardcoded to "fixture" anymore).
fn emitGeneric(allocator: std.mem.Allocator, c_alias: []const u8, handle_table_name: []const u8, zig_out: *std.ArrayList(u8), go_out: *std.ArrayList(u8), desc: Reflect.FnDescriptor) GenError!void {
    const is_destroy = std.mem.indexOf(u8, desc.name, "destroy") != null;
    const req_fields = try collectReqFields(allocator, desc.params[0..desc.params_len]);
    const out_param = findStructOutParam(desc.params[0..desc.params_len]);
    switch (desc.@"return".kind) {
        .void_kind, .int_primitive, .float_primitive, .opaque_handle => {},
        else => return error.UnsupportedShape,
    }

    const pascal = try pascalCase(allocator, desc.name);
    const camel = try camelCase(allocator, desc.name);

    // --- Zig request struct ---
    try zig_out.appendSlice(allocator, "const ");
    try zig_out.appendSlice(allocator, pascal);
    try zig_out.appendSlice(allocator, "Request = struct {");
    for (req_fields) |f| {
        try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator, " p{d}: {s},", .{ f.index, zigFieldType(f.param) }));
    }
    try zig_out.appendSlice(allocator, " };\n\n");

    // --- Zig host trampoline ---
    try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\pub fn {s}HostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {{
        \\    _ = n_inputs;
        \\    _ = n_outputs;
        \\    _ = user_data;
        \\    const allocator = std.heap.page_allocator;
        \\    const input_bytes = host_fn_util.readGuestBytes(allocator, plugin, &inputs[0]) catch {{
        \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{{}});
        \\        return;
        \\    }};
        \\    defer allocator.free(input_bytes);
        \\    const parsed = std.json.parseFromSlice({s}Request, allocator, input_bytes, .{{ .allocate = .alloc_always }}) catch |err| {{
        \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {{}}", .{{err}});
        \\        return;
        \\    }};
        \\    defer parsed.deinit();
        \\    const req = parsed.value;
        \\
    , .{ camel, pascal }));
    // A zero-parameter bound function (e.g. zlib's `zlibCompileFlags(void)`,
    // Stage 2.2's own real end-to-end proof) has an empty Request struct,
    // so nothing below ever references `req` -- a real, previously-latent
    // "unused local constant" compile error, only surfaced once a genuine
    // zero-arg C function was actually bound for the first time.
    if (req_fields.len == 0) try zig_out.appendSlice(allocator, "    _ = req;\n");

    // Stage 2.10: every `.byte_buffer_out` param encountered in the loop
    // below (paired with its own `.length_ptr_inout`, per
    // `collectReqFields`'s own validation) is recorded here so the
    // response-building code further down can emit one base64-encoded
    // output field per real out-buffer, once the real call (and thus the
    // real written length) is known.
    var buffer_out_fields: std.ArrayList(struct { buf_index: usize, len_index: usize }) = .empty;

    var call_args: std.ArrayList(u8) = .empty;
    var pi: usize = 0;
    while (pi < desc.params_len) : (pi += 1) {
        const p = desc.params[pi];
        if (pi > 0) try call_args.appendSlice(allocator, ", ");
        switch (p.kind) {
            .int_primitive, .float_primitive => try call_args.appendSlice(allocator, try std.fmt.allocPrint(allocator, "req.p{d}", .{pi})),
            .opaque_handle => {
                try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
                    \\    const p{d}_ptr = {s}.get(req.p{d}) orelse {{
                    \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "unknown handle {{d}}", .{{req.p{d}}});
                    \\        return;
                    \\    }};
                    \\
                , .{ pi, handle_table_name, pi, pi }));
                try call_args.appendSlice(allocator, try std.fmt.allocPrint(allocator, "p{d}_ptr", .{pi}));
            },
            .struct_out_ptr => {
                try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "    var out_p{d}: {s}.{s} = undefined;\n", .{ pi, c_alias, p.type_name }));
                try call_args.appendSlice(allocator, try std.fmt.allocPrint(allocator, "&out_p{d}", .{pi}));
            },
            .byte_buffer_in => {
                // `collectReqFields` (already run above, before any of
                // this text was emitted) guarantees a `.byte_buffer_in`
                // param is always immediately followed by an
                // `.int_primitive` length one -- so the real, decoded
                // byte slice's own length is used directly as that C
                // call argument, and the length param itself never
                // becomes its own request field/Go parameter (a real
                // wire-format simplification: the guest only ever
                // supplies one `[]byte`, matching real Go idiom, not a
                // redundant buffer+length pair). Wire encoding is plain
                // base64 in the JSON string field -- Go's own
                // `encoding/json` already marshals/unmarshals a `[]byte`
                // field as base64 automatically, so the guest side needs
                // no special-casing at all; only the host side needs a
                // real decode step, via `std.base64` (this codebase's
                // first real use of it).
                try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
                    \\    const p{0d}_len = std.base64.standard.Decoder.calcSizeForSlice(req.p{0d}) catch {{
                    \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "invalid base64 for p{0d}", .{{}});
                    \\        return;
                    \\    }};
                    \\    const p{0d}_buf = allocator.alloc(u8, p{0d}_len) catch {{
                    \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory decoding p{0d}", .{{}});
                    \\        return;
                    \\    }};
                    \\    defer allocator.free(p{0d}_buf);
                    \\    std.base64.standard.Decoder.decode(p{0d}_buf, req.p{0d}) catch {{
                    \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "invalid base64 for p{0d}", .{{}});
                    \\        return;
                    \\    }};
                    \\
                , .{pi}));
                try call_args.appendSlice(allocator, try std.fmt.allocPrint(allocator, "p{d}_buf.ptr, @intCast(p{d}_buf.len)", .{ pi, pi }));
                pi += 1; // consume the paired length param
            },
            .byte_buffer_out => {
                // The paired `.length_ptr_inout` (guaranteed present by
                // `collectReqFields`) is the request field carrying the
                // guest-supplied *capacity* -- the host allocates a real
                // buffer of exactly that size (entirely host-owned, the
                // guest never supplies or sees the buffer itself, only
                // its capacity going in and its real encoded contents
                // coming back out) and passes a mutable copy of the
                // capacity as the real in/out length pointer, since the
                // real C call may write fewer bytes than the capacity.
                const len_idx = pi + 1;
                const len_param = desc.params[len_idx];
                const len_ty = zigIntType(len_param.int_bits, len_param.int_signed);
                try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
                    \\    const p{0d}_buf = allocator.alloc(u8, @intCast(req.p{1d})) catch {{
                    \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory allocating p{0d}", .{{}});
                    \\        return;
                    \\    }};
                    \\    defer allocator.free(p{0d}_buf);
                    \\    var p{1d}_len: {2s} = @intCast(req.p{1d});
                    \\
                , .{ pi, len_idx, len_ty }));
                try call_args.appendSlice(allocator, try std.fmt.allocPrint(allocator, "p{d}_buf.ptr, &p{d}_len", .{ pi, len_idx }));
                try buffer_out_fields.append(allocator, .{ .buf_index = pi, .len_index = len_idx });
                pi += 1; // consume the paired length_ptr_inout param
            },
            else => return error.UnsupportedShape,
        }
    }

    const call_expr = try std.fmt.allocPrint(allocator, "{s}.{s}({s})", .{ c_alias, desc.name, try call_args.toOwnedSlice(allocator) });
    switch (desc.@"return".kind) {
        .void_kind => try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "    {s};\n", .{call_expr})),
        else => try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "    const result = {s};\n", .{call_expr})),
    }

    if (is_destroy) {
        for (desc.params[0..desc.params_len], 0..) |p, i| {
            if (p.kind == .opaque_handle) {
                try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "    {s}.remove(req.p{d});\n", .{ handle_table_name, i }));
                break;
            }
        }
    }

    // Stage 2.10: encode each real `.byte_buffer_out` result -- only now,
    // after the real call, is `p{len_index}_len` known (the real number
    // of bytes the call actually wrote, which may be less than the
    // guest-supplied capacity). Uses `std.base64.standard.Encoder`
    // (paired with `.byte_buffer_in`'s own `.Decoder` from Stage 2.9) --
    // Go's own `encoding/json` decodes a `[]byte` response field from
    // base64 automatically, so the guest side needs no special handling.
    for (buffer_out_fields.items) |bof| {
        try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            \\    const p{0d}_encoded_len = std.base64.standard.Encoder.calcSize(p{1d}_len);
            \\    const p{0d}_encoded_buf = allocator.alloc(u8, p{0d}_encoded_len) catch {{
            \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory encoding p{0d}", .{{}});
            \\        return;
            \\    }};
            \\    defer allocator.free(p{0d}_encoded_buf);
            \\    const p{0d}_encoded = std.base64.standard.Encoder.encode(p{0d}_encoded_buf, p{0d}_buf[0..p{1d}_len]);
            \\
        , .{ bof.buf_index, bof.len_index }));
    }

    var resp_fields: std.ArrayList(u8) = .empty;
    if (out_param) |op| {
        for (op.param.struct_fields[0..op.param.struct_fields_len], 0..) |f, fi| {
            if (fi > 0) try resp_fields.appendSlice(allocator, ", ");
            try resp_fields.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\\\"{s}\\\":{{d}}", .{f.name}));
        }
    }
    for (buffer_out_fields.items) |bof| {
        if (resp_fields.items.len > 0) try resp_fields.appendSlice(allocator, ", ");
        try resp_fields.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\\\"out{d}\\\":\\\"{{s}}\\\"", .{bof.buf_index}));
    }
    switch (desc.@"return".kind) {
        .void_kind => {},
        .opaque_handle => {
            try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
                \\    const result_id = {s}.insert(result orelse {{
                \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "{s} returned a null handle", .{{}});
                \\        return;
                \\    }}) orelse {{
                \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "handle table full", .{{}});
                \\        return;
                \\    }};
                \\
            , .{ handle_table_name, desc.name }));
            if (resp_fields.items.len > 0) try resp_fields.appendSlice(allocator, ", ");
            try resp_fields.appendSlice(allocator, "\\\"handle\\\":{d}");
        },
        else => {
            if (resp_fields.items.len > 0) try resp_fields.appendSlice(allocator, ", ");
            try resp_fields.appendSlice(allocator, "\\\"result\\\":{d}");
        },
    }

    var fmt_args: std.ArrayList(u8) = .empty;
    if (out_param) |op| {
        for (op.param.struct_fields[0..op.param.struct_fields_len], 0..) |f, fi| {
            if (fi > 0) try fmt_args.appendSlice(allocator, ", ");
            try fmt_args.appendSlice(allocator, try std.fmt.allocPrint(allocator, "out_p{d}.{s}", .{ op.index, f.name }));
        }
    }
    // Same relative position as `resp_fields`' own byte_buffer_out loop
    // above -- these two lists' entries are matched up positionally by
    // the runtime `std.fmt.bufPrint` call the generated code makes, so
    // any reordering here must happen in both places at once.
    for (buffer_out_fields.items) |bof| {
        if (fmt_args.items.len > 0) try fmt_args.appendSlice(allocator, ", ");
        try fmt_args.appendSlice(allocator, try std.fmt.allocPrint(allocator, "p{d}_encoded", .{bof.buf_index}));
    }
    switch (desc.@"return".kind) {
        .void_kind => {},
        .opaque_handle => {
            if (fmt_args.items.len > 0) try fmt_args.appendSlice(allocator, ", ");
            try fmt_args.appendSlice(allocator, "result_id");
        },
        else => {
            if (fmt_args.items.len > 0) try fmt_args.appendSlice(allocator, ", ");
            try fmt_args.appendSlice(allocator, "result");
        },
    }

    if (resp_fields.items.len == 0) {
        try zig_out.appendSlice(allocator, "    host_fn_util.writeGuestBytes(plugin, &outputs[0], \"{}\");\n}\n\n");
    } else {
        // Stage 2.10: a heap-allocated buffer via `allocPrint`, not the
        // old fixed `[256]u8` stack array via `bufPrint` -- a real
        // response can now legitimately exceed 256 bytes (a base64-
        // encoded `.byte_buffer_out` result, e.g. real compressed/
        // decompressed data, has no fixed upper bound the way a handful
        // of scalar/struct fields always did).
        try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            \\    const json_out = std.fmt.allocPrint(allocator, "{{{{{s}}}}}", .{{{s}}}) catch return;
            \\    defer allocator.free(json_out);
            \\    host_fn_util.writeGuestBytes(plugin, &outputs[0], json_out);
            \\}}
            \\
            \\
        , .{ resp_fields.items, fmt_args.items }));
    }

    // --- Go side ---
    var go_params: std.ArrayList(u8) = .empty;
    var req_json_fields: std.ArrayList(u8) = .empty;
    var req_json_args: std.ArrayList(u8) = .empty;
    for (req_fields, 0..) |f, fi| {
        if (fi > 0) {
            try go_params.appendSlice(allocator, ", ");
            try req_json_fields.appendSlice(allocator, ",");
        }
        try go_params.appendSlice(allocator, try std.fmt.allocPrint(allocator, "p{d} {s}", .{ f.index, goFieldType(f.param) }));
        try req_json_fields.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"p{d}\":%v", .{f.index}));
        if (req_json_args.items.len > 0) try req_json_args.appendSlice(allocator, ", ");
        try req_json_args.appendSlice(allocator, try std.fmt.allocPrint(allocator, "p{d}", .{f.index}));
    }

    var go_results: std.ArrayList(u8) = .empty;
    var go_decode_fields: std.ArrayList(u8) = .empty;
    if (out_param) |op| {
        for (op.param.struct_fields[0..op.param.struct_fields_len]) |f| {
            const field_pascal = try pascalCase(allocator, f.name);
            try go_decode_fields.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\t{s} {s} `json:\"{s}\"`\n", .{ field_pascal, if (f.is_float) "float32" else "int32", f.name }));
        }
    }
    // Stage 2.10: one `[]byte` field per real `.byte_buffer_out` result --
    // Go's own `encoding/json` decodes a `[]byte` struct field from a
    // base64 JSON string automatically, matching exactly how a `[]byte`
    // *request* field already encodes automatically (Stage 2.9) -- no
    // special-casing needed on this side at all.
    for (buffer_out_fields.items) |bof| {
        try go_decode_fields.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\tOut{d} []byte `json:\"out{d}\"`\n", .{ bof.buf_index, bof.buf_index }));
    }
    switch (desc.@"return".kind) {
        .void_kind => {},
        .opaque_handle => try go_decode_fields.appendSlice(allocator, "\tHandle uint32 `json:\"handle\"`\n"),
        else => try go_decode_fields.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\tResult {s} `json:\"result\"`\n", .{goFieldType(desc.@"return")})),
    }
    _ = &go_results;

    try go_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\//go:wasmimport extism:host/user {s}
        \\func {s}Host(uint64) uint64
        \\
        \\type {s}Response struct {{
        \\{s}    Error string `json:"error,omitempty"`
        \\}}
        \\
        \\func {s}({s}) ({s}Response, error) {{
        \\    body, err := json.Marshal(struct {{
        \\
    , .{ desc.name, camel, pascal, go_decode_fields.items, pascal, go_params.items, pascal }));

    for (req_fields) |f| {
        try go_out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\t\tP{d} {s} `json:\"p{d}\"`\n", .{ f.index, goFieldType(f.param), f.index }));
    }
    try go_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\    }}{{{s}}})
        \\    if err != nil {{
        \\        return {s}Response{{}}, err
        \\    }}
        \\    var resp {s}Response
        \\    if err := json.Unmarshal(pdk.ParamBytes({s}Host(pdk.ResultBytes(body))), &resp); err != nil {{
        \\        return {s}Response{{}}, err
        \\    }}
        \\    if resp.Error != "" {{
        \\        return {s}Response{{}}, errors.New(resp.Error)
        \\    }}
        \\    return resp, nil
        \\}}
        \\
        \\
    , .{ req_json_args.items, pascal, pascal, camel, pascal, pascal }));
}

/// Hand-modeled emission for a callback-registration/trigger pair -- see
/// this file's own doc comment for why this isn't generic (Stage 2.1 only
/// generalizes the *naming*, still assuming the exact fixture-shaped
/// signature: `set_cb_desc` is `(opaque_handle, callback_ptr, userdata_ptr)
/// -> void`, `trigger_desc` is `(opaque_handle, int_primitive) -> void`).
/// `library` names the generated native callback function + the stand-in
/// invocation-record buffer; `set_cb_desc`/`trigger_desc`'s own real
/// C/Go names (not a hardcoded "fixture" string) drive everything else,
/// via the same pascalCase/camelCase derivation `emitGeneric` uses.
fn emitCallbackPair(allocator: std.mem.Allocator, library: []const u8, c_alias: []const u8, handle_table_name: []const u8, zig_out: *std.ArrayList(u8), go_out: *std.ArrayList(u8), set_cb_desc: Reflect.FnDescriptor, trigger_desc: Reflect.FnDescriptor) GenError!void {
    const set_pascal = try pascalCase(allocator, set_cb_desc.name);
    const set_camel = try camelCase(allocator, set_cb_desc.name);
    const trigger_pascal = try pascalCase(allocator, trigger_desc.name);
    const trigger_camel = try camelCase(allocator, trigger_desc.name);
    const native_cb_name = try std.fmt.allocPrint(allocator, "{s}NativeCallback", .{try camelCase(allocator, library)});
    const last_invocation_name = try std.fmt.allocPrint(allocator, "{s}_last_invocation", .{library});

    try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\const {s}Request = struct {{ p0: u32 }};
        \\const {s}Request = struct {{ p0: u32, p1: i32 }};
        \\
        \\/// Stage 1 stand-in for real `natyv_dispatch` delivery (Stage 2's
        \\/// job) -- records that a real C-to-native callback invocation
        \\/// happened, keyed by handle id, so a test can observe the real
        \\/// native round trip without any guest wired up yet.
        \\pub var {s}: [handle_table_capacity]?i32 = @splat(null);
        \\
        \\pub fn {s}(value: c_int, user_data: ?*anyopaque) callconv(.c) void {{
        \\    const id: usize = @intFromPtr(user_data);
        \\    if (id < {s}.len) {s}[id] = value;
        \\}}
        \\
        \\pub fn {s}HostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {{
        \\    _ = n_inputs;
        \\    _ = n_outputs;
        \\    _ = user_data;
        \\    const allocator = std.heap.page_allocator;
        \\    const input_bytes = host_fn_util.readGuestBytes(allocator, plugin, &inputs[0]) catch {{
        \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{{}});
        \\        return;
        \\    }};
        \\    defer allocator.free(input_bytes);
        \\    const parsed = std.json.parseFromSlice({s}Request, allocator, input_bytes, .{{ .allocate = .alloc_always }}) catch |err| {{
        \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {{}}", .{{err}});
        \\        return;
        \\    }};
        \\    defer parsed.deinit();
        \\    const req = parsed.value;
        \\    const ptr = {s}.get(req.p0) orelse {{
        \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "unknown handle {{d}}", .{{req.p0}});
        \\        return;
        \\    }};
        \\    {s}.{s}(ptr, {s}, @ptrFromInt(req.p0));
        \\    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{{}}");
        \\}}
        \\
        \\pub fn {s}HostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {{
        \\    _ = n_inputs;
        \\    _ = n_outputs;
        \\    _ = user_data;
        \\    const allocator = std.heap.page_allocator;
        \\    const input_bytes = host_fn_util.readGuestBytes(allocator, plugin, &inputs[0]) catch {{
        \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{{}});
        \\        return;
        \\    }};
        \\    defer allocator.free(input_bytes);
        \\    const parsed = std.json.parseFromSlice({s}Request, allocator, input_bytes, .{{ .allocate = .alloc_always }}) catch |err| {{
        \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {{}}", .{{err}});
        \\        return;
        \\    }};
        \\    defer parsed.deinit();
        \\    const req = parsed.value;
        \\    const ptr = {s}.get(req.p0) orelse {{
        \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "unknown handle {{d}}", .{{req.p0}});
        \\        return;
        \\    }};
        \\    {s}.{s}(ptr, req.p1);
        \\    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{{}}");
        \\}}
        \\
        \\
    , .{
        set_pascal,           trigger_pascal, // Request struct names
        last_invocation_name, native_cb_name,
        last_invocation_name, last_invocation_name,
        set_camel, // HostFn name
        set_pascal, // Request type in parseFromSlice
        handle_table_name,
        c_alias, set_cb_desc.name, native_cb_name, // the real C call
        trigger_camel, // HostFn name
        trigger_pascal, // Request type in parseFromSlice
        handle_table_name,
        c_alias, trigger_desc.name, // the real C call
    }));

    try go_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\//go:wasmimport extism:host/user {s}
        \\func {s}Host(uint64) uint64
        \\
        \\//go:wasmimport extism:host/user {s}
        \\func {s}Host(uint64) uint64
        \\
        \\// {s}Callbacks mirrors the shared per-event-type handler-map
        \\// pattern in sdk/go/widgets/internal/dispatch.go -- not yet wired to
        \\// anything real (that's Stage 2's job, see this file's doc comment).
        \\var {s}Callbacks = map[uint32]func(int32){{}}
        \\
        \\func {s}(handle uint32, cb func(int32)) error {{
        \\    {s}Callbacks[handle] = cb
        \\    body, err := json.Marshal(struct {{
        \\        P0 uint32 `json:"p0"`
        \\    }}{{handle}})
        \\    if err != nil {{
        \\        return err
        \\    }}
        \\    var resp struct {{
        \\        Error string `json:"error,omitempty"`
        \\    }}
        \\    if err := json.Unmarshal(pdk.ParamBytes({s}Host(pdk.ResultBytes(body))), &resp); err != nil {{
        \\        return err
        \\    }}
        \\    if resp.Error != "" {{
        \\        return errors.New(resp.Error)
        \\    }}
        \\    return nil
        \\}}
        \\
        \\func {s}(handle uint32, value int32) error {{
        \\    body, err := json.Marshal(struct {{
        \\        P0 uint32 `json:"p0"`
        \\        P1 int32  `json:"p1"`
        \\    }}{{handle, value}})
        \\    if err != nil {{
        \\        return err
        \\    }}
        \\    var resp struct {{
        \\        Error string `json:"error,omitempty"`
        \\    }}
        \\    if err := json.Unmarshal(pdk.ParamBytes({s}Host(pdk.ResultBytes(body))), &resp); err != nil {{
        \\        return err
        \\    }}
        \\    if resp.Error != "" {{
        \\        return errors.New(resp.Error)
        \\    }}
        \\    return nil
        \\}}
        \\
        \\
    , .{
        set_cb_desc.name,  set_camel, // wasmimport + host func
        trigger_desc.name, trigger_camel,
        library, library, // Callbacks map doc + decl
        set_pascal, library, set_camel, // SetCallback func
        trigger_pascal, trigger_camel, // Trigger func
    }));
}

fn findOpaqueHandleTypeName(descriptors: []const Reflect.FnDescriptor) ?[]const u8 {
    for (descriptors) |desc| {
        if (desc.@"return".kind == .opaque_handle) return desc.@"return".type_name;
        for (desc.params[0..desc.params_len]) |p| {
            if (p.kind == .opaque_handle) return p.type_name;
        }
    }
    return null;
}

fn findTriggerDesc(descriptors: []const Reflect.FnDescriptor) ?Reflect.FnDescriptor {
    for (descriptors) |desc| {
        if (std.mem.indexOf(u8, desc.name, "trigger") != null) return desc;
    }
    return null;
}

fn findSetCallbackDesc(descriptors: []const Reflect.FnDescriptor) ?Reflect.FnDescriptor {
    for (descriptors) |desc| {
        for (desc.params[0..desc.params_len]) |p| {
            if (p.kind == .callback_ptr) return desc;
        }
    }
    return null;
}

/// `library` names this `bindings` entry (drives the handle-table/native-
/// callback variable names and the generated Go package name -- see
/// `emitGeneric`/`emitCallbackPair`'s own doc comments for why a hardcoded
/// "fixture" string can't work once more than one library can be bound).
/// `header` is the exact string handed to `@cInclude` in the generated
/// file's own header -- `include_dirs` (from the real `bindings` entry)
/// aren't embedded in the generated text at all, since they're compiler
/// `-I` flags for whoever compiles this file, not part of its source.
pub fn generate(allocator: std.mem.Allocator, library: []const u8, header: []const u8, descriptors: []const Reflect.FnDescriptor) GenError!Output {
    var zig_out: std.ArrayList(u8) = .empty;
    var go_out: std.ArrayList(u8) = .empty;

    const c_alias = try std.fmt.allocPrint(allocator, "{s}_c", .{library});
    const handle_table_name = try std.fmt.allocPrint(allocator, "{s}_handle_table", .{library});
    const handle_type_name = findOpaqueHandleTypeName(descriptors) orelse "anyopaque";

    // Relative imports assuming this generated file lands directly in
    // `src/bindgen/`, sibling to `BindingsC.zig`/`BindingsHostFnUtil.zig`/
    // `HandleTable.zig` -- `src/cli/Bind.zig`'s real, final per-app
    // destination for it (Stage 2.2), and also where `build.zig`'s own
    // `bindgen_generated_check` verification writes its fixture-based
    // `generated_check.zig`. Plain, non-escaping sibling imports (Zig
    // treats a `root_source_file`'s own directory as a hard module
    // boundary a relative import can't cross with `../`, confirmed the
    // hard way while first wiring this stage's own real compile check).
    // `BindingsC.zig`/`BindingsHostFnUtil.zig` are `Bindings`' own private
    // duplicates of `c.zig`/`host_fn_util.zig` (not the real, shared
    // files) -- see `BindingsC.zig`'s own doc comment for why: `Bindings`
    // is compiled as a genuinely separate Zig module from natyv-core's
    // real `root` module, and a single physical file can never belong to
    // two different modules at once, so it can't relatively reach back
    // into files `root` already claims.
    //
    // The `@cImport` alias is `pub` so anything else that needs to call
    // the same real C library directly (e.g. `GeneratedFixtureCheck.zig`'s
    // own real-native-round-trip test) can reach this *exact* translate-c
    // instance via `@import("<this file>").<c_alias>` rather than
    // declaring a second, incompatible `@cImport` over the same header.
    try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\// Code generated by natyv bind. DO NOT EDIT.
        \\const std = @import("std");
        \\const c = @import("BindingsC.zig").c;
        \\const host_fn_util = @import("BindingsHostFnUtil.zig");
        \\const HandleTable = @import("HandleTable.zig").HandleTable;
        \\pub const {s} = @cImport({{
        \\    @cInclude("{s}");
        \\}});
        \\
        \\const handle_table_capacity = 64;
        \\pub var {s}: HandleTable({s}.{s}, handle_table_capacity) = .{{}};
        \\
        \\
    , .{ c_alias, header, handle_table_name, c_alias, handle_type_name }));
    // Always `package main`, never `package {library}` -- this file's real
    // destination (`src/cli/Bind.zig`) is always `guest/<library>_bindings_generated.go`,
    // sibling to the app's own `guest/main.go`, and Go requires every file
    // in one directory to share the same package declaration. A real,
    // previously-unnoticed bug found while building Stage 2.2's own
    // end-to-end proof (a real zlib binding): `library`-as-package-name
    // compiled fine in isolation (this file's own unit tests, and Stage
    // 2.1's `Bind.zig` test, only ever asserted on the generated text
    // directly) but would have made `tinygo build .` fail immediately with
    // "found packages main and <library>" the first time it ever ran
    // against a real guest directory.
    try go_out.appendSlice(allocator,
        \\// Code generated by natyv bind. DO NOT EDIT.
        \\package main
        \\
        \\import (
        \\    "encoding/json"
        \\    "errors"
        \\
        \\    "github.com/extism/go-pdk"
        \\)
        \\
        \\
    );

    const trigger_desc = findTriggerDesc(descriptors);
    const set_cb_desc = findSetCallbackDesc(descriptors);
    var handled_callback_pair = false;
    var host_functions: std.ArrayList(HostFunctionInfo) = .empty;
    for (descriptors) |desc| {
        const has_callback = for (desc.params[0..desc.params_len]) |p| {
            if (p.kind == .callback_ptr) break true;
        } else false;
        const is_trigger = trigger_desc != null and std.mem.eql(u8, desc.name, trigger_desc.?.name);
        if (has_callback or is_trigger) {
            if (!handled_callback_pair) {
                if (set_cb_desc == null or trigger_desc == null) return error.UnsupportedShape;
                try emitCallbackPair(allocator, library, c_alias, handle_table_name, &zig_out, &go_out, set_cb_desc.?, trigger_desc.?);
                try host_functions.append(allocator, .{ .extism_name = set_cb_desc.?.name, .zig_fn_name = try std.fmt.allocPrint(allocator, "{s}HostFn", .{try camelCase(allocator, set_cb_desc.?.name)}) });
                try host_functions.append(allocator, .{ .extism_name = trigger_desc.?.name, .zig_fn_name = try std.fmt.allocPrint(allocator, "{s}HostFn", .{try camelCase(allocator, trigger_desc.?.name)}) });
                handled_callback_pair = true;
            }
            continue;
        }
        try emitGeneric(allocator, c_alias, handle_table_name, &zig_out, &go_out, desc);
        try host_functions.append(allocator, .{ .extism_name = desc.name, .zig_fn_name = try std.fmt.allocPrint(allocator, "{s}HostFn", .{try camelCase(allocator, desc.name)}) });
    }

    return .{ .zig_source = try zig_out.toOwnedSlice(allocator), .go_source = try go_out.toOwnedSlice(allocator), .host_functions = try host_functions.toOwnedSlice(allocator) };
}

// Test-only: the real fixture's `@cImport` namespace + its own full
// function list -- production callers (`Bind.zig`) build both of these
// from a real `bindings` config entry instead (see that file's own doc
// comment). Kept here, not in `Reflect.zig`, since this file's tests are
// the only real remaining fixture-specific callers (per `Reflect.zig`'s
// own Stage 2.1 generalization note).
const fixture_c = @import("fixture.zig").c;
const fixture_allowlist = [_][]const u8{
    "fixture_create",
    "fixture_destroy",
    "fixture_get_point",
    "fixture_set_callback",
    "fixture_trigger",
};

test "generate: fixture_create emits an opaque_handle-returning trampoline + Go wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const desc = try Reflect.describe(fixture_c, "fixture_create");
    var zig_out: std.ArrayList(u8) = .empty;
    var go_out: std.ArrayList(u8) = .empty;
    try emitGeneric(allocator, "fixture_c", "fixture_handle_table", &zig_out, &go_out, desc);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "fixture_handle_table.insert") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "pub fn fixtureCreateHostFn") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out.items, "func FixtureCreate(") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out.items, "Handle uint32 `json:\"handle\"`") != null);
}

test "generate: fixture_destroy removes the handle table entry after the call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const desc = try Reflect.describe(fixture_c, "fixture_destroy");
    var zig_out: std.ArrayList(u8) = .empty;
    var go_out: std.ArrayList(u8) = .empty;
    try emitGeneric(allocator, "fixture_c", "fixture_handle_table", &zig_out, &go_out, desc);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "fixture_handle_table.remove(req.p0)") != null);
}

test "generate: fixture_get_point flattens struct out-param fields plus the int return into the response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const desc = try Reflect.describe(fixture_c, "fixture_get_point");
    var zig_out: std.ArrayList(u8) = .empty;
    var go_out: std.ArrayList(u8) = .empty;
    try emitGeneric(allocator, "fixture_c", "fixture_handle_table", &zig_out, &go_out, desc);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "out_p1.x") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "out_p1.y") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out.items, "X int32 `json:\"x\"`") != null);
    // `FixtureStatus` (the enum-as-status return) translate-c collapses to
    // a bare `c_uint`, which is *unsigned* -- Stage 2.9's new width/
    // signedness-aware marshaling now correctly emits `uint32`, not the
    // old blind `int32` every earlier stage's own int handling defaulted
    // to regardless of the real C type's actual signedness.
    try std.testing.expect(std.mem.indexOf(u8, go_out.items, "Result uint32 `json:\"result\"`") != null);
}

test "generate: fixture_checksum -- wide unsigned ints marshal correctly and the byte buffer + its paired length collapse into one []byte param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const desc = try Reflect.describe(fixture_c, "fixture_checksum");
    var zig_out: std.ArrayList(u8) = .empty;
    var go_out: std.ArrayList(u8) = .empty;
    try emitGeneric(allocator, "fixture_c", "fixture_handle_table", &zig_out, &go_out, desc);

    // Zig side: p0 (crc seed) is a real u64, not the old blind i32; p1 is
    // the byte buffer's own base64-text wire field; p2 (the real C
    // function's length param) never appears as its own request field at
    // all -- it's derived from the decoded buffer's real length instead.
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "p0: u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "p1: []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "p2:") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "std.base64.standard.Decoder.decode(p1_buf, req.p1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "fixture_c.fixture_checksum(req.p0, p1_buf.ptr, @intCast(p1_buf.len))") != null);

    // Go side: the wrapper takes a plain []byte, no redundant length
    // param; the request body and response both use uint64 for the wide
    // unsigned crc/result values, not int32.
    try std.testing.expect(std.mem.indexOf(u8, go_out.items, "func FixtureChecksum(p0 uint64, p1 []byte)") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out.items, "P0 uint64 `json:\"p0\"`") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out.items, "P1 []byte `json:\"p1\"`") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out.items, "Result uint64 `json:\"result\"`") != null);
}

test "generate: fixture_pack -- byte_buffer_out + length_ptr_inout, mirrors real zlib compress/uncompress's own out-buffer shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const desc = try Reflect.describe(fixture_c, "fixture_pack");
    var zig_out: std.ArrayList(u8) = .empty;
    var go_out: std.ArrayList(u8) = .empty;
    try emitGeneric(allocator, "fixture_c", "fixture_handle_table", &zig_out, &go_out, desc);

    // Zig side: p1 (dest's own real length pointer) is the guest-supplied
    // *capacity* value (a plain u64 request field) -- p0 (the dest buffer
    // itself) never appears as its own request field at all, since it's
    // entirely host-allocated. p2/p3 (source + its length) behave exactly
    // like Stage 2.9's own byte_buffer_in pairing already proved.
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "p1: u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "p0:") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "p3:") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "const p0_buf = allocator.alloc(u8, @intCast(req.p1))") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "var p1_len: u64 = @intCast(req.p1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "fixture_c.fixture_pack(p0_buf.ptr, &p1_len, p2_buf.ptr, @intCast(p2_buf.len))") != null);
    // The real out-buffer result is base64-encoded only *after* the real
    // call, using the real written length (p1_len), not the guest's
    // original capacity request -- proves the encode step reads the
    // in/out value's post-call state, not its pre-call one.
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "std.base64.standard.Encoder.calcSize(p1_len)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "std.base64.standard.Encoder.encode(p0_encoded_buf, p0_buf[0..p1_len])") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_out.items, "\\\"out0\\\":\\\"{s}\\\"") != null);

    // Go side: the wrapper takes the capacity as a plain uint64 (p1) and
    // the source as a plain []byte (p2) -- never the raw dest/destLen/
    // source/sourceLen 1:1 C signature. The response decodes the real
    // out-buffer as a plain []byte (Go's own encoding/json base64-decodes
    // it automatically) alongside the real int status code.
    try std.testing.expect(std.mem.indexOf(u8, go_out.items, "func FixturePack(p1 uint64, p2 []byte)") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out.items, "Out0 []byte `json:\"out0\"`") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out.items, "Result int32 `json:\"result\"`") != null);
}

test "generate: full fixture allowlist produces non-empty, distinct Zig and Go sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var descs: [fixture_allowlist.len]Reflect.FnDescriptor = undefined;
    inline for (fixture_allowlist, 0..) |name, i| {
        descs[i] = try Reflect.describe(fixture_c, name);
    }
    const out = try generate(allocator, "fixture", "fixture.h", &descs);
    try std.testing.expect(std.mem.indexOf(u8, out.zig_source, "fixtureCreateHostFn") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.zig_source, "fixtureDestroyHostFn") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.zig_source, "fixtureGetPointHostFn") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.zig_source, "fixtureSetCallbackHostFn") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.zig_source, "fixtureTriggerHostFn") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.go_source, "func FixtureCreate(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.go_source, "func FixtureSetCallback(") != null);

    try std.testing.expectEqual(@as(usize, 5), out.host_functions.len);
    try std.testing.expectEqualStrings("fixture_create", out.host_functions[0].extism_name);
    try std.testing.expectEqualStrings("fixtureCreateHostFn", out.host_functions[0].zig_fn_name);
    try std.testing.expectEqualStrings("fixture_set_callback", out.host_functions[3].extism_name);
    try std.testing.expectEqualStrings("fixtureSetCallbackHostFn", out.host_functions[3].zig_fn_name);
    try std.testing.expectEqualStrings("fixture_trigger", out.host_functions[4].extism_name);
    try std.testing.expectEqualStrings("fixtureTriggerHostFn", out.host_functions[4].zig_fn_name);
}

test "generate: a second, distinctly-named library produces its own distinct names, proving genericity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var descs: [fixture_allowlist.len]Reflect.FnDescriptor = undefined;
    inline for (fixture_allowlist, 0..) |name, i| {
        descs[i] = try Reflect.describe(fixture_c, name);
    }
    const out = try generate(allocator, "widget", "fixture.h", &descs);
    try std.testing.expect(std.mem.indexOf(u8, out.zig_source, "widget_handle_table") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.zig_source, "widget_c") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.zig_source, "fixture_handle_table") == null);
    // Always "package main" now (see `generate`'s own doc comment on the
    // real bug this corrected) -- proves the library-name genericity via
    // the Zig-side names above instead.
    try std.testing.expect(std.mem.indexOf(u8, out.go_source, "package main") != null);
}
