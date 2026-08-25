//! `natyv get`'s comptime reflection layer -- Stage 1 of
//! ~/.claude/plans/lexical-wishing-penguin.md. `@cImport`s the fixture C
//! header and, for a caller-supplied, comptime-known function name, walks
//! its real signature via `@field(c, name)` + `@typeInfo` to produce a
//! plain-data `FnDescriptor` that `Codegen.zig` can turn into Zig
//! host-trampoline + Go guest-wrapper source text.
//!
//! **Never enumerate `@typeInfo(c).@"struct".decls` and reflect every
//! decl.** A real spike this session found that even this fixture's
//! completely dependency-free header still produces a `cimport.zig`
//! containing platform-injected macro decls (`__nonnull` on this machine)
//! that fail to translate and become `@compileError` stubs -- enumerating
//! *every* decl forces Zig to evaluate all of them, including the broken
//! ones, and the whole file fails to compile for a reason that has nothing
//! to do with the fixture's own real API surface. Referencing a specific,
//! known-by-name decl (what `describe` below does) never touches the
//! broken ones, since Zig's lazy comptime analysis only evaluates
//! declarations something actually names. This is also a better design on
//! its own merits, not just a workaround: the dev supplies an explicit
//! allowlist of exactly which C functions to bind, matching Extism's own
//! existing allowlist philosophy for network hosts.
const std = @import("std");

// A same-directory relative import, not a duplicate `@cImport` -- two
// separate `@cImport` blocks over the same header produce two distinct,
// incompatible Zig types (e.g. two different `FixtureHandle` opaque
// types), so this file and `Codegen.zig`'s generated output (which
// imports `fixture.zig` by name, see that file's own doc comment) always
// agree on exactly one underlying translate-c instance.
pub const c = @import("fixture.zig").c;

/// The complete, real API surface this fixture proves the generator
/// against -- exactly the CLAUDE.md-confirmed proof list (opaque handle
/// create/destroy, one struct out-param, one enum-as-status return, one
/// callback registration + a real invocation path).
pub const allowlist = [_][]const u8{
    "fixture_create",
    "fixture_destroy",
    "fixture_get_point",
    "fixture_set_callback",
    "fixture_trigger",
};

/// The four real shapes Stage 1 supports, plus the two building blocks
/// (plain int/float, and `void` for a function with no return value) they
/// compose from. Anything else `classify` encounters is `error.Unsupported`
/// -- an explicit, visible codegen error, never a silent mismarshal.
pub const ParamKind = enum {
    void_kind,
    int_primitive,
    float_primitive,
    opaque_handle,
    struct_out_ptr,
    callback_ptr,
    userdata_ptr,
};

pub const StructFieldDesc = struct {
    name: []const u8,
    is_float: bool,
};

/// Small, fixed-capacity bounds for Stage 1's own real fixture surface --
/// plain fields-by-value everywhere below, never a slice pointing back
/// into a caller's local array. `describe`/`classify` build these values
/// through several nested calls, and a slice into a plain (non-`comptime`)
/// local array declared partway through that chain would be a real
/// dangling-pointer bug once the declaring call frame returns -- found the
/// hard way (a real segfault) while first building this file. Copying
/// small fixed arrays by value sidesteps the whole lifetime question
/// rather than requiring every caller to get `comptime`-forcing exactly
/// right.
pub const max_params = 8;
pub const max_struct_fields = 8;
pub const max_callback_params = 4;

pub const Param = struct {
    kind: ParamKind,
    /// The C type's own name, e.g. "FixtureHandle"/"FixturePoint" --
    /// populated only for `.opaque_handle`/`.struct_out_ptr`, used by
    /// `Codegen.zig` to name the generated handle table / mirrored struct.
    /// `@typeName`/a struct field's own `.name` are both backed by static
    /// rodata, not a local array, so holding these slices directly is safe
    /// regardless of comptime/runtime call context.
    type_name: []const u8 = "",
    /// Populated only for `.struct_out_ptr`; use `struct_fields[0..struct_fields_len]`.
    struct_fields: [max_struct_fields]StructFieldDesc = undefined,
    struct_fields_len: usize = 0,
    /// Populated only for `.callback_ptr`: the callback's own param kinds,
    /// restricted to `.int_primitive`/`.float_primitive`/`.userdata_ptr` --
    /// Stage 1 doesn't support a callback whose own params need further
    /// unwrapping (e.g. a struct or nested callback param). Use
    /// `callback_params[0..callback_params_len]`.
    callback_params: [max_callback_params]ParamKind = undefined,
    callback_params_len: usize = 0,
};

pub const FnDescriptor = struct {
    name: []const u8,
    /// Use `params[0..params_len]`.
    params: [max_params]Param = undefined,
    params_len: usize = 0,
    @"return": Param,
};

pub const ReflectError = error{ UnsupportedType, GenericFunction };

/// `@typeName` on a translate-c-produced type returns the fully-qualified
/// name inside this file's own anonymous `c` import (e.g.
/// "cimport.struct_FixtureHandle" for an opaque forward-declared struct,
/// "cimport.FixturePoint" for a real one) -- strip the module prefix and,
/// for a forward-declared opaque type, translate-c's own synthesized
/// "struct_" prefix, down to the plain C name a generated binding should
/// actually use.
fn cleanTypeName(comptime raw: []const u8) []const u8 {
    const last_dot = std.mem.lastIndexOfScalar(u8, raw, '.');
    const base = if (last_dot) |i| raw[i + 1 ..] else raw;
    const prefix = "struct_";
    if (std.mem.startsWith(u8, base, prefix)) return base[prefix.len..];
    return base;
}

fn isAnyopaquePtr(comptime T: type) bool {
    const ti = @typeInfo(T);
    if (ti != .optional) return false;
    const child_ti = @typeInfo(ti.optional.child);
    return child_ti == .pointer and child_ti.pointer.child == anyopaque;
}

fn classifyCallbackParam(comptime T: type) ReflectError!ParamKind {
    if (isAnyopaquePtr(T)) return .userdata_ptr;
    return switch (@typeInfo(T)) {
        .int => .int_primitive,
        .float => .float_primitive,
        else => error.UnsupportedType,
    };
}

fn classify(comptime T: type) ReflectError!Param {
    const ti = @typeInfo(T);
    switch (ti) {
        .void => return .{ .kind = .void_kind },
        .int => return .{ .kind = .int_primitive },
        .float => return .{ .kind = .float_primitive },
        .optional => |opt| {
            if (isAnyopaquePtr(T)) return .{ .kind = .userdata_ptr };

            const child_ti = @typeInfo(opt.child);
            if (child_ti != .pointer) return error.UnsupportedType;
            const pointee = child_ti.pointer.child;
            const pointee_ti = @typeInfo(pointee);

            switch (pointee_ti) {
                .@"opaque" => return .{ .kind = .opaque_handle, .type_name = cleanTypeName(@typeName(pointee)) },
                .@"fn" => |fn_info| {
                    if (fn_info.params.len > max_callback_params) return error.UnsupportedType;
                    var result: Param = .{ .kind = .callback_ptr };
                    inline for (fn_info.params, 0..) |p, i| {
                        result.callback_params[i] = try classifyCallbackParam(p.type.?);
                    }
                    result.callback_params_len = fn_info.params.len;
                    return result;
                },
                else => return error.UnsupportedType,
            }
        },
        .pointer => |ptr| {
            const pointee_ti = @typeInfo(ptr.child);
            if (pointee_ti != .@"struct") return error.UnsupportedType;
            const fields_ti = pointee_ti.@"struct".fields;
            if (fields_ti.len > max_struct_fields) return error.UnsupportedType;
            var result: Param = .{ .kind = .struct_out_ptr, .type_name = cleanTypeName(@typeName(ptr.child)) };
            inline for (fields_ti, 0..) |f, i| {
                result.struct_fields[i] = .{ .name = f.name, .is_float = @typeInfo(f.type) == .float };
            }
            result.struct_fields_len = fields_ti.len;
            return result;
        },
        else => return error.UnsupportedType,
    }
}

/// `name` must be one of `allowlist`'s own entries, comptime-known --
/// never call this with a runtime string (see this file's own doc comment
/// on why blind enumeration is unsafe; a comptime-unknown name would
/// require exactly that).
///
/// **`fn_info.is_generic` must be checked before touching `.type`/
/// `.return_type` on anything** -- confirmed by a real spike (2026-08-25):
/// a C function-like macro whose body is a single expression (e.g.
/// `#define SQUARE(x) ((x)*(x))`) translates via `@cImport` into a real,
/// callable `pub inline fn` -- but a *generic* one (`anytype` params, an
/// `anytype` return inferred from the argument), since a macro has no
/// concrete parameter types until it's actually invoked. Every param's
/// `.type` and the `.return_type` are `null` on a generic function
/// (confirmed directly), and unwrapping either with `.?` crashes --
/// caught by writing exactly this case as a test before it could ever
/// reach a real dev's config. natyv intentionally does not support
/// binding these: a dev who needs one should write a small real C
/// function wrapper around the macro in their own header instead --
/// simpler than trying to require the dev to also specify concrete
/// argument types just to make one macro bindable.
pub fn describe(comptime name: []const u8) ReflectError!FnDescriptor {
    const val = @field(c, name);
    const fn_info = @typeInfo(@TypeOf(val)).@"fn";
    if (fn_info.is_generic) return error.GenericFunction;
    if (fn_info.params.len > max_params) return error.UnsupportedType;
    const ret = try classify(fn_info.return_type.?);
    var result: FnDescriptor = .{ .name = name, .@"return" = ret };
    inline for (fn_info.params, 0..) |p, i| {
        result.params[i] = try classify(p.type.?);
    }
    result.params_len = fn_info.params.len;
    return result;
}

test "fixture_create: one int param, opaque_handle return" {
    const desc = try describe("fixture_create");
    try std.testing.expectEqualStrings("fixture_create", desc.name);
    try std.testing.expectEqual(@as(usize, 1), desc.params_len);
    try std.testing.expectEqual(ParamKind.int_primitive, desc.params[0].kind);
    try std.testing.expectEqual(ParamKind.opaque_handle, desc.@"return".kind);
    try std.testing.expectEqualStrings("FixtureHandle", desc.@"return".type_name);
}

test "fixture_destroy: one opaque_handle param, void return" {
    const desc = try describe("fixture_destroy");
    try std.testing.expectEqual(@as(usize, 1), desc.params_len);
    try std.testing.expectEqual(ParamKind.opaque_handle, desc.params[0].kind);
    try std.testing.expectEqualStrings("FixtureHandle", desc.params[0].type_name);
    try std.testing.expectEqual(ParamKind.void_kind, desc.@"return".kind);
}

test "fixture_get_point: opaque_handle + struct_out_ptr params, int (enum-as-status) return" {
    const desc = try describe("fixture_get_point");
    try std.testing.expectEqual(@as(usize, 2), desc.params_len);
    try std.testing.expectEqual(ParamKind.opaque_handle, desc.params[0].kind);
    try std.testing.expectEqual(ParamKind.struct_out_ptr, desc.params[1].kind);
    try std.testing.expectEqualStrings("FixturePoint", desc.params[1].type_name);
    try std.testing.expectEqual(@as(usize, 2), desc.params[1].struct_fields_len);
    try std.testing.expectEqualStrings("x", desc.params[1].struct_fields[0].name);
    try std.testing.expect(!desc.params[1].struct_fields[0].is_float);
    try std.testing.expectEqualStrings("y", desc.params[1].struct_fields[1].name);
    // FixtureStatus is a plain C enum -- translate-c collapses it to a bare
    // c_uint (finding 2 in the plan file), so it reflects as a plain int,
    // not a distinct enum shape. This is the real, confirmed behavior, not
    // an oversight.
    try std.testing.expectEqual(ParamKind.int_primitive, desc.@"return".kind);
}

test "fixture_set_callback: opaque_handle + callback_ptr + userdata_ptr params" {
    const desc = try describe("fixture_set_callback");
    try std.testing.expectEqual(@as(usize, 3), desc.params_len);
    try std.testing.expectEqual(ParamKind.opaque_handle, desc.params[0].kind);
    try std.testing.expectEqual(ParamKind.callback_ptr, desc.params[1].kind);
    try std.testing.expectEqual(@as(usize, 2), desc.params[1].callback_params_len);
    try std.testing.expectEqual(ParamKind.int_primitive, desc.params[1].callback_params[0]);
    try std.testing.expectEqual(ParamKind.userdata_ptr, desc.params[1].callback_params[1]);
    try std.testing.expectEqual(ParamKind.userdata_ptr, desc.params[2].kind);
    try std.testing.expectEqual(ParamKind.void_kind, desc.@"return".kind);
}

test "fixture_trigger: opaque_handle + int params, void return" {
    const desc = try describe("fixture_trigger");
    try std.testing.expectEqual(@as(usize, 2), desc.params_len);
    try std.testing.expectEqual(ParamKind.opaque_handle, desc.params[0].kind);
    try std.testing.expectEqual(ParamKind.int_primitive, desc.params[1].kind);
    try std.testing.expectEqual(ParamKind.void_kind, desc.@"return".kind);
}

test "allowlist covers every function this fixture proof requires" {
    try std.testing.expectEqual(@as(usize, 5), allowlist.len);
}

test "describe rejects a translated function-like macro cleanly instead of crashing on a null .type unwrap" {
    try std.testing.expectError(error.GenericFunction, describe("FIXTURE_DOUBLE"));
}
