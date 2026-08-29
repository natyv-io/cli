const std = @import("std");

// Explicit manual override for Extism's install prefix -- see
// natyv-io/core's own build.zig for the full reasoning (identical here).
fn extismPrefixOverride(b: *std.Build) ?[]const u8 {
    if (b.option([]const u8, "extism-prefix", "Path to the Extism install prefix (dir containing include/ and lib/) -- overrides the default fetched-package Extism")) |p| return p;
    if (b.graph.environ_map.get("NATYV_EXTISM_PREFIX")) |p| return p;
    return null;
}

fn extismDependencyName(target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .macos => switch (target.cpu.arch) {
            .aarch64 => "extism_aarch64_macos",
            .x86_64 => "extism_x86_64_macos",
            else => std.process.fatal("natyv: no vendored Extism build for macos/{s}", .{@tagName(target.cpu.arch)}),
        },
        .linux => switch (target.cpu.arch) {
            .x86_64 => "extism_x86_64_linux_gnu",
            .aarch64 => "extism_aarch64_linux_gnu",
            else => std.process.fatal("natyv: no vendored Extism build for linux/{s}", .{@tagName(target.cpu.arch)}),
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => "extism_x86_64_windows_gnu",
            else => std.process.fatal("natyv: no vendored Extism build for windows/{s}", .{@tagName(target.cpu.arch)}),
        },
        else => std.process.fatal("natyv: no vendored Extism build for {s}", .{@tagName(target.os.tag)}),
    };
}

const ExtismPaths = struct { include: std.Build.LazyPath, lib: std.Build.LazyPath };
fn resolveExtism(b: *std.Build, target: std.Target, extism_prefix: ?[]const u8) ?ExtismPaths {
    if (extism_prefix) |prefix| {
        return .{
            .include = .{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) },
            .lib = .{ .cwd_relative = b.pathJoin(&.{ prefix, "lib", "libextism.a" }) },
        };
    }
    const dep = b.lazyDependency(extismDependencyName(target), .{}) orelse return null;
    return .{ .include = dep.path("."), .lib = dep.path("libextism.a") };
}

// The `natyv` CLI links real Extism directly -- the AppImage-packing
// plugin (`PackageAppImage.zig`, reached via `Bundle.zig`) calls a real
// embedded Extism plugin, and there's no standalone tool to shell out to
// the way `sips`/`iconutil` exist on every Mac for macOS packaging.
fn linkExtism(b: *std.Build, module: *std.Build.Module, extism_prefix: ?[]const u8) void {
    module.link_libc = true;

    const target = module.resolved_target.?.result;
    if (resolveExtism(b, target, extism_prefix)) |extism| {
        module.addIncludePath(extism.include);
        module.addObjectFile(extism.lib);
    }

    if (target.os.tag == .windows) {
        module.linkSystemLibrary("ws2_32", .{});
        module.linkSystemLibrary("userenv", .{});
        module.linkSystemLibrary("bcrypt", .{});
        if (b.lazyDependency("llvm_mingw", .{})) |mingw_dep| {
            module.addObjectFile(mingw_dep.path("x86_64-w64-mingw32/lib/libunwind.a"));
        }
        module.addCSourceFile(.{ .file = b.path("vendor/mingw_compat/cfguard_dummy.c"), .flags = &.{} });
    }
    if (target.os.tag == .linux) {
        module.linkSystemLibrary("unwind", .{});
    }
}

// Windows icon generation (`src/cli/WindowsIcon.zig`) needs the stb
// decode/resize/encode trio -- a separate compile from natyv-core's own
// runtime-only, STBI_NO_STDIO'd copy (two different binaries, no link
// collision).
fn linkStbIconTools(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    module.addIncludePath(b.path("vendor/stb"));
    module.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_icon_tools_impl.c"),
        .flags = &.{},
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const extism_prefix = extismPrefixOverride(b);

    // `Config` comes from natyv-io/shared -- see natyv-io/core's own
    // build.zig for the full reasoning (identical here: both repos need
    // the exact same conf.natyv.json schema/parser).
    const shared_dep = b.dependency("shared", .{ .target = target, .optimize = optimize });
    const config_mod = shared_dep.module("Config");

    // Styling system: pure text-in/tree-out, zero SDL/Clay dependency.
    // Named module since Stage 7's real stylesheet discovery (`Prepare`)
    // and `Resolver` both need to reach the exact same compiled
    // `Stylesheet.zig` so a `Stylesheet.StyleSheet` produced by one is
    // accepted by the other's own `resolve()`.
    const stylesheet_mod = b.createModule(.{
        .root_source_file = b.path("src/styling/Stylesheet.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stylesheet_tests = b.addTest(.{ .root_module = stylesheet_mod });
    const run_stylesheet_tests = b.addRunArtifact(stylesheet_tests);

    const resolver_mod = b.createModule(.{
        .root_source_file = b.path("src/styling/Resolver.zig"),
        .target = target,
        .optimize = optimize,
    });
    resolver_mod.addImport("Stylesheet", stylesheet_mod);
    const resolver_tests = b.addTest(.{ .root_module = resolver_mod });
    const run_resolver_tests = b.addRunArtifact(resolver_tests);

    const styling_codegen_mod = b.createModule(.{
        .root_source_file = b.path("src/styling/Codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    styling_codegen_mod.addImport("Resolver", resolver_mod);
    const codegen_tests = b.addTest(.{ .root_module = styling_codegen_mod });
    const run_codegen_tests = b.addRunArtifact(codegen_tests);

    // `.ntx` tooling: pure text-in/tree-out, same "zero SDL/Clay
    // dependency" reasoning as the stylesheet tests above.
    const ntx_parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ntx/Parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ntx_parser_tests = b.addRunArtifact(ntx_parser_tests);

    const ntx_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/ntx/Parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ntx_expose_mod = b.createModule(.{
        .root_source_file = b.path("src/ntx/Expose.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntx_expose_mod.addImport("Parser", ntx_parser_mod);

    const ntx_expose_tests = b.addTest(.{ .root_module = ntx_expose_mod });
    const run_ntx_expose_tests = b.addRunArtifact(ntx_expose_tests);

    const ntx_codegen_module = b.createModule(.{
        .root_source_file = b.path("src/ntx/Codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntx_codegen_module.addImport("Resolver", resolver_mod);
    ntx_codegen_module.addImport("Expose", ntx_expose_mod);
    ntx_codegen_module.addImport("Parser", ntx_parser_mod);
    const ntx_codegen_tests = b.addTest(.{ .root_module = ntx_codegen_module });
    const run_ntx_codegen_tests = b.addRunArtifact(ntx_codegen_tests);

    const ntx_validate_module = b.createModule(.{
        .root_source_file = b.path("src/ntx/Validate.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntx_validate_module.addImport("Resolver", resolver_mod);
    ntx_validate_module.addImport("Expose", ntx_expose_mod);
    ntx_validate_module.addImport("Codegen", ntx_codegen_module);
    const ntx_validate_tests = b.addTest(.{ .root_module = ntx_validate_module });
    const run_ntx_validate_tests = b.addRunArtifact(ntx_validate_tests);

    // Binding generator: `Reflect`/`Codegen` (the CLI-time codegen half --
    // `BindingsC.zig`/`HandleTable.zig`/`BindingsHostFnUtil.zig`, the
    // runtime-linked half, live in natyv-io/core instead). Pure text-in/
    // text-out, zero SDL/Extism/Clay dependency -- only `-I fixtures/bindgen`
    // so their shared `@cImport` of fixture.h resolves.
    const bindgen_reflect_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bindgen/Reflect.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bindgen_reflect_tests.root_module.addIncludePath(b.path("fixtures/bindgen"));
    const run_bindgen_reflect_tests = b.addRunArtifact(bindgen_reflect_tests);

    const bindgen_codegen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bindgen/Codegen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bindgen_codegen_tests.root_module.addIncludePath(b.path("fixtures/bindgen"));
    const run_bindgen_codegen_tests = b.addRunArtifact(bindgen_codegen_tests);

    // `natyv get -zig=`/`natyv bind`'s own Zig-package-fetch mechanism and
    // `natyv get -c=<url>`/`natyv bind`'s own C-source vendoring mechanism
    // -- promoted to real, named, shared modules since they're reachable
    // from more than one place (`cli_module` via `Get.zig`'s relative
    // import, `bind_module`/`ntx_prepare_module` directly).
    const zigfetch_module = b.createModule(.{
        .root_source_file = b.path("src/cli/ZigFetch.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vendor_module = b.createModule(.{
        .root_source_file = b.path("src/cli/Vendor.zig"),
        .target = target,
        .optimize = optimize,
    });
    vendor_module.addImport("ZigFetch", zigfetch_module);

    const bind_module = b.createModule(.{
        .root_source_file = b.path("src/cli/Bind.zig"),
        .target = target,
        .optimize = optimize,
    });
    bind_module.addImport("Config", config_mod);
    bind_module.addImport("ZigFetch", zigfetch_module);
    bind_module.addImport("Vendor", vendor_module);
    const bind_tests = b.addTest(.{ .root_module = bind_module });
    const run_bind_tests = b.addRunArtifact(bind_tests);

    const ntx_prepare_module = b.createModule(.{
        .root_source_file = b.path("src/cli/Prepare.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntx_prepare_module.addImport("Expose", ntx_expose_mod);
    ntx_prepare_module.addImport("Codegen", ntx_codegen_module);
    ntx_prepare_module.addImport("Validate", ntx_validate_module);
    ntx_prepare_module.addImport("Resolver", resolver_mod);
    ntx_prepare_module.addImport("Stylesheet", stylesheet_mod);
    ntx_prepare_module.addImport("StylingCodegen", styling_codegen_mod);
    ntx_prepare_module.addImport("Config", config_mod);
    ntx_prepare_module.addImport("Bind", bind_module);
    const ntx_prepare_tests = b.addTest(.{ .root_module = ntx_prepare_module });
    const run_ntx_prepare_tests = b.addRunArtifact(ntx_prepare_tests);

    const compile_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/Compile.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_compile_tests = b.addRunArtifact(compile_tests);

    const build_cache_module = b.createModule(.{
        .root_source_file = b.path("src/cli/BuildCache.zig"),
        .target = target,
        .optimize = optimize,
    });
    build_cache_module.addImport("Codegen", ntx_codegen_module);
    const build_cache_tests = b.addTest(.{ .root_module = build_cache_module });
    const run_build_cache_tests = b.addRunArtifact(build_cache_tests);

    const bundle_module = b.createModule(.{
        .root_source_file = b.path("src/cli/Bundle.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkExtism(b, bundle_module, extism_prefix);
    linkStbIconTools(b, bundle_module);
    const bundle_tests = b.addTest(.{ .root_module = bundle_module });
    const run_bundle_tests = b.addRunArtifact(bundle_tests);

    const init_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/Init.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_init_tests = b.addRunArtifact(init_tests);

    const pkgconfig_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/PkgConfig.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_pkgconfig_tests = b.addRunArtifact(pkgconfig_tests);

    const zigfetch_tests = b.addTest(.{ .root_module = zigfetch_module });
    const run_zigfetch_tests = b.addRunArtifact(zigfetch_tests);

    const vendor_tests = b.addTest(.{ .root_module = vendor_module });
    const run_vendor_tests = b.addRunArtifact(vendor_tests);

    const get_module = b.createModule(.{
        .root_source_file = b.path("src/cli/Get.zig"),
        .target = target,
        .optimize = optimize,
    });
    get_module.addImport("Config", config_mod);
    get_module.addImport("Vendor", vendor_module);
    const get_tests = b.addTest(.{ .root_module = get_module });
    const run_get_tests = b.addRunArtifact(get_tests);

    // `natyv build`'s bundling step needs natyv-core's own buildable
    // source tree on disk to run `zig build` against -- baked into the CLI
    // binary at compile time as a real default (overridable at runtime via
    // `NATYV_CORE_SRC`). Post-split, this repo's own root is no longer a
    // meaningful default (natyv-core's source doesn't live here) -- kept
    // only as a harmless fallback for `zig build test`/`zig build` (which
    // never read this value); any real `natyv build` invocation needs a
    // real natyv-io/core checkout pointed at explicitly, either via this
    // option at CLI-build time or `NATYV_CORE_SRC` at runtime. A real
    // packaging layer (Homebrew formula, Scoop manifest) sets this to
    // wherever it vendors natyv-core's source.
    const natyv_core_src_default = b.option([]const u8, "natyv-core-src", "Compile-time default path to a natyv-io/core checkout, baked into the natyv CLI binary -- overridable at runtime via NATYV_CORE_SRC. Real packaging wrappers set this to wherever they vendor natyv-core's source.") orelse (b.build_root.path orelse ".");
    const cli_build_options = b.addOptions();
    cli_build_options.addOption([]const u8, "natyv_core_src_default", natyv_core_src_default);

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("Config", config_mod);
    cli_module.addImport("Prepare", ntx_prepare_module);
    cli_module.addImport("BuildCache", build_cache_module);
    cli_module.addImport("ZigFetch", zigfetch_module);
    cli_module.addImport("Vendor", vendor_module);
    cli_module.addOptions("build_options", cli_build_options);
    linkExtism(b, cli_module, extism_prefix);
    linkStbIconTools(b, cli_module);

    const cli_exe = b.addExecutable(.{
        .name = "natyv",
        .root_module = cli_module,
    });
    b.installArtifact(cli_exe);

    const cli_run_cmd = b.addRunArtifact(cli_exe);
    cli_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| cli_run_cmd.addArgs(args);

    const cli_step = b.step("cli", "Run the natyv CLI, e.g. `zig build cli -- prepare conf.natyv.json`");
    cli_step.dependOn(&cli_run_cmd.step);

    const cli_test_module = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_test_module.addImport("Config", config_mod);
    cli_test_module.addImport("Prepare", ntx_prepare_module);
    cli_test_module.addImport("BuildCache", build_cache_module);
    cli_test_module.addImport("ZigFetch", zigfetch_module);
    cli_test_module.addImport("Vendor", vendor_module);
    cli_test_module.addOptions("build_options", cli_build_options);
    linkExtism(b, cli_test_module, extism_prefix);
    linkStbIconTools(b, cli_test_module);
    const cli_tests = b.addTest(.{ .root_module = cli_test_module });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    // The `ntx-lsp` binary, deliberately standalone rather than a `natyv`
    // subcommand -- decouples its stdio/JSON-RPC process lifecycle from
    // the CLI's own argv/exit-code conventions.
    const ntx_lsp_module = b.createModule(.{
        .root_source_file = b.path("src/lsp/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntx_lsp_module.addImport("Expose", ntx_expose_mod);
    ntx_lsp_module.addImport("Codegen", ntx_codegen_module);
    const ntx_lsp_exe = b.addExecutable(.{
        .name = "ntx-lsp",
        .root_module = ntx_lsp_module,
    });
    b.installArtifact(ntx_lsp_exe);

    const ntx_lsp_test_module = b.createModule(.{
        .root_source_file = b.path("src/lsp/Server.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntx_lsp_test_module.addImport("Expose", ntx_expose_mod);
    ntx_lsp_test_module.addImport("Codegen", ntx_codegen_module);
    const ntx_lsp_tests = b.addTest(.{ .root_module = ntx_lsp_test_module });
    const run_ntx_lsp_tests = b.addRunArtifact(ntx_lsp_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_stylesheet_tests.step);
    test_step.dependOn(&run_resolver_tests.step);
    test_step.dependOn(&run_codegen_tests.step);
    test_step.dependOn(&run_ntx_parser_tests.step);
    test_step.dependOn(&run_ntx_expose_tests.step);
    test_step.dependOn(&run_ntx_codegen_tests.step);
    test_step.dependOn(&run_ntx_validate_tests.step);
    test_step.dependOn(&run_bindgen_reflect_tests.step);
    test_step.dependOn(&run_bindgen_codegen_tests.step);
    test_step.dependOn(&run_ntx_prepare_tests.step);
    test_step.dependOn(&run_compile_tests.step);
    test_step.dependOn(&run_build_cache_tests.step);
    test_step.dependOn(&run_bundle_tests.step);
    test_step.dependOn(&run_init_tests.step);
    test_step.dependOn(&run_bind_tests.step);
    test_step.dependOn(&run_pkgconfig_tests.step);
    test_step.dependOn(&run_zigfetch_tests.step);
    test_step.dependOn(&run_vendor_tests.step);
    test_step.dependOn(&run_get_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_ntx_lsp_tests.step);
}
