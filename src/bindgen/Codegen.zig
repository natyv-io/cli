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
//! `int_primitive`/`float_primitive`/`opaque_handle`, with at most one
//! `struct_out_ptr` param, and whose return is
//! `void_kind`/`int_primitive`/`float_primitive`/`opaque_handle` --
//! `fixture_create`/`fixture_destroy`/`fixture_get_point` all go through
//! this path unmodified, and it's meant to generalize to zlib's own
//! functions later (Stage 3) without new per-function code. Every
//! non-out-param becomes a positional JSON request field (`p0`, `p1`, ...
//! -- C's type system doesn't preserve parameter names, so this is a real,
//! accepted limitation, not an oversight); an `opaque_handle` param is
//! actually a `u32` id resolved through `HandleTable.zig`, never a raw
//! pointer crossing the wire; a `struct_out_ptr` param's fields are
//! flattened directly into the response object; an `opaque_handle` return
//! becomes a new id inserted into the same table (`"handle"` response
//! field), a primitive return becomes a `"result"` field.
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

pub const Output = struct {
    zig_source: []const u8,
    go_source: []const u8,
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

fn zigPrimitiveType(kind: Reflect.ParamKind) []const u8 {
    return switch (kind) {
        .int_primitive => "i32",
        .float_primitive => "f32",
        else => unreachable,
    };
}

fn goPrimitiveType(kind: Reflect.ParamKind) []const u8 {
    return switch (kind) {
        .int_primitive => "int32",
        .float_primitive => "float32",
        else => unreachable,
    };
}

/// A non-out-param's request-field role -- separated from `Reflect.Param`
/// so the emitter doesn't need to re-derive "which index is this in the
/// request struct" (out-params don't get one) in three different places.
const ReqField = struct {
    index: usize,
    kind: Reflect.ParamKind,
};

fn collectReqFields(allocator: std.mem.Allocator, params: []const Reflect.Param) ![]ReqField {
    var fields: std.ArrayList(ReqField) = .empty;
    for (params, 0..) |p, i| {
        switch (p.kind) {
            .int_primitive, .float_primitive, .opaque_handle => try fields.append(allocator, .{ .index = i, .kind = p.kind }),
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
    if (out_param == null) {
        for (desc.params[0..desc.params_len]) |p| if (p.kind != .int_primitive and p.kind != .float_primitive and p.kind != .opaque_handle) return error.UnsupportedShape;
    }
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
        const ty: []const u8 = if (f.kind == .opaque_handle) "u32" else zigPrimitiveType(f.kind);
        try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator, " p{d}: {s},", .{ f.index, ty }));
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

    var call_args: std.ArrayList(u8) = .empty;
    for (desc.params[0..desc.params_len], 0..) |p, i| {
        if (i > 0) try call_args.appendSlice(allocator, ", ");
        switch (p.kind) {
            .int_primitive, .float_primitive => try call_args.appendSlice(allocator, try std.fmt.allocPrint(allocator, "req.p{d}", .{i})),
            .opaque_handle => {
                try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
                    \\    const p{d}_ptr = {s}.get(req.p{d}) orelse {{
                    \\        host_fn_util.writeErrorJson(plugin, &outputs[0], "unknown handle {{d}}", .{{req.p{d}}});
                    \\        return;
                    \\    }};
                    \\
                , .{ i, handle_table_name, i, i }));
                try call_args.appendSlice(allocator, try std.fmt.allocPrint(allocator, "p{d}_ptr", .{i}));
            },
            .struct_out_ptr => {
                try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "    var out_p{d}: {s}.{s} = undefined;\n", .{ i, c_alias, p.type_name }));
                try call_args.appendSlice(allocator, try std.fmt.allocPrint(allocator, "&out_p{d}", .{i}));
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

    var resp_fields: std.ArrayList(u8) = .empty;
    if (out_param) |op| {
        for (op.param.struct_fields[0..op.param.struct_fields_len], 0..) |f, fi| {
            if (fi > 0) try resp_fields.appendSlice(allocator, ", ");
            try resp_fields.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\\\"{s}\\\":{{d}}", .{f.name}));
        }
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
        try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            \\    var out_buf: [256]u8 = undefined;
            \\    const json_out = std.fmt.bufPrint(&out_buf, "{{{{{s}}}}}", .{{{s}}}) catch return;
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
        const go_ty: []const u8 = if (f.kind == .opaque_handle) "uint32" else goPrimitiveType(f.kind);
        try go_params.appendSlice(allocator, try std.fmt.allocPrint(allocator, "p{d} {s}", .{ f.index, go_ty }));
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
    switch (desc.@"return".kind) {
        .void_kind => {},
        .opaque_handle => try go_decode_fields.appendSlice(allocator, "\tHandle uint32 `json:\"handle\"`\n"),
        else => try go_decode_fields.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\tResult {s} `json:\"result\"`\n", .{goPrimitiveType(desc.@"return".kind)})),
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

    for (req_fields, 0..) |f, fi| {
        const go_ty: []const u8 = if (f.kind == .opaque_handle) "uint32" else goPrimitiveType(f.kind);
        try go_out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\t\tP{d} {s} `json:\"p{d}\"`\n", .{ f.index, go_ty, f.index }));
        _ = fi;
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
    // natyv-core's own `src/`, sibling to the real `c.zig`/
    // `host_fn_util.zig` -- a plain, non-escaping relative import (Zig
    // treats a `root_source_file`'s own directory as a hard module
    // boundary a relative import can't cross with `../`, confirmed the
    // hard way while first wiring this stage's own real compile check in
    // build.zig; every existing cross-directory case in this project
    // works around it with a named module instead, e.g. `Config.zig`'s
    // own doc comment). Stage 2.1 keeps this one placement purely for its
    // own real-compile verification (see build.zig's
    // `bindgen_generated_check` test) -- Stage 2.2 decides the real
    // per-app placement convention.
    //
    // The `@cImport` alias is `pub` so anything else that needs to call
    // the same real C library directly (e.g. `GeneratedFixtureCheck.zig`'s
    // own real-native-round-trip test) can reach this *exact* translate-c
    // instance via `@import("<this file>").<c_alias>` rather than
    // declaring a second, incompatible `@cImport` over the same header.
    try zig_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\// Code generated by natyv bind. DO NOT EDIT.
        \\const std = @import("std");
        \\const c = @import("c.zig").c;
        \\const host_fn_util = @import("host_fn_util.zig");
        \\const HandleTable = @import("bindgen/HandleTable.zig").HandleTable;
        \\pub const {s} = @cImport({{
        \\    @cInclude("{s}");
        \\}});
        \\
        \\const handle_table_capacity = 64;
        \\pub var {s}: HandleTable({s}.{s}, handle_table_capacity) = .{{}};
        \\
        \\
    , .{ c_alias, header, handle_table_name, c_alias, handle_type_name }));
    try go_out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\// Code generated by natyv bind. DO NOT EDIT.
        \\package {s}
        \\
        \\import (
        \\    "encoding/json"
        \\    "errors"
        \\
        \\    "github.com/extism/go-pdk"
        \\)
        \\
        \\
    , .{library}));

    const trigger_desc = findTriggerDesc(descriptors);
    const set_cb_desc = findSetCallbackDesc(descriptors);
    var handled_callback_pair = false;
    for (descriptors) |desc| {
        const has_callback = for (desc.params[0..desc.params_len]) |p| {
            if (p.kind == .callback_ptr) break true;
        } else false;
        const is_trigger = trigger_desc != null and std.mem.eql(u8, desc.name, trigger_desc.?.name);
        if (has_callback or is_trigger) {
            if (!handled_callback_pair) {
                if (set_cb_desc == null or trigger_desc == null) return error.UnsupportedShape;
                try emitCallbackPair(allocator, library, c_alias, handle_table_name, &zig_out, &go_out, set_cb_desc.?, trigger_desc.?);
                handled_callback_pair = true;
            }
            continue;
        }
        try emitGeneric(allocator, c_alias, handle_table_name, &zig_out, &go_out, desc);
    }

    return .{ .zig_source = try zig_out.toOwnedSlice(allocator), .go_source = try go_out.toOwnedSlice(allocator) };
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
    try std.testing.expect(std.mem.indexOf(u8, out.go_source, "package widget") != null);
}
