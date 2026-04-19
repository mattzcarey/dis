// dis — single Zig build for the two-binary monorepo.
//
//   dis-engine   → engine/src/main.zig
//   dis-infer    → infer/src/main.zig
//   dis-infer-smoke → infer/smoke/client.zig   (dev-only tool)
//
// Shared code lives in `common/` and is exposed as named modules
// (`cbor`, `log`) that each root module imports.
//
// Top-level steps:
//   zig build                    build both binaries (+ smoke)
//   zig build test               run BOTH test suites
//   zig build test-engine        engine tests only
//   zig build test-infer         infer tests only
//   zig build run-engine -- config.json
//   zig build run-infer  -- /tmp/dis-infer.sock
//
// Options:
//   -Dwith_llama=true            enable real llama.cpp in dis-infer (M2).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Path to the llama.cpp install root. On macOS, Homebrew lives at
    // /opt/homebrew and ships `libllama.dylib` + headers there. Override
    // with `-Dllama_prefix=/some/other/path` when bringing your own
    // build (e.g. linker pointed at a source-compile later).
    const llama_prefix = b.option(
        []const u8,
        "llama_prefix",
        "Install prefix where llama.cpp lives (headers in <prefix>/include, libs in <prefix>/lib). Default: /opt/homebrew.",
    ) orelse "/opt/homebrew";

    // ── llama.h → Zig module ────────────────────────────────────────
    //
    // translate-c runs at build time and hands us a Zig module with
    // every `llama_*` / `ggml_*` symbol declared. The Zig wrapper
    // (`third_party/llama.cpp.zig/llama.zig`) imports it as "llama.h".
    //
    // We feed translate-c a tiny stub that #includes all the headers
    // we care about, so one module covers llama + ggml types.

    const llama_h_stub = b.addWriteFiles();
    const stub_path = llama_h_stub.add("llama_all.h",
        \\#include <llama.h>
        \\
    );

    const translate_llama_h = b.addTranslateC(.{
        .root_source_file = stub_path,
        .target = target,
        .optimize = optimize,
    });
    translate_llama_h.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ llama_prefix, "include" }) });
    const llama_h_mod = translate_llama_h.createModule();

    // Wrapper module — the "llama" import users reach for.
    const llama_mod = b.createModule(.{
        .root_source_file = b.path("third_party/llama.cpp.zig/llama.zig"),
        .target = target,
        .optimize = optimize,
    });
    llama_mod.addImport("llama.h", llama_h_mod);
    // Linker config propagates from module → any exe that imports it.
    llama_mod.link_libc = true;
    llama_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ llama_prefix, "lib" }) });
    // libllama.dylib already pulls in libggml + libggml-base transitively
    // via its install_name; linking `-lllama` is enough.
    llama_mod.linkSystemLibrary("llama", .{});

    // ── Shared modules ──────────────────────────────────────────────
    //
    // Both binaries `@import("cbor")` and `@import("log")`. The .zig
    // files never reach across the `common/` boundary by relative path.

    const cbor_mod = b.createModule(.{
        .root_source_file = b.path("common/cbor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const log_mod = b.createModule(.{
        .root_source_file = b.path("common/log.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── dis-engine ──────────────────────────────────────────────────
    const engine_root = b.createModule(.{
        .root_source_file = b.path("engine/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_root.addImport("cbor", cbor_mod);
    engine_root.addImport("log", log_mod);

    const engine_exe = b.addExecutable(.{
        .name = "dis-engine",
        .root_module = engine_root,
    });
    b.installArtifact(engine_exe);

    const engine_step = b.step("engine", "Build dis-engine");
    engine_step.dependOn(&b.addInstallArtifact(engine_exe, .{}).step);

    const run_engine = b.addRunArtifact(engine_exe);
    run_engine.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_engine.addArgs(args);
    const run_engine_step = b.step("run-engine", "Run dis-engine");
    run_engine_step.dependOn(&run_engine.step);

    // ── dis-infer ───────────────────────────────────────────────────
    //
    // Re-usable library module so both the binary and the smoke client
    // can import `infer.frames`, `infer.messages`, etc. from the same
    // root.

    const infer_lib = b.createModule(.{
        .root_source_file = b.path("infer/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    infer_lib.addImport("cbor", cbor_mod);
    infer_lib.addImport("log", log_mod);
    infer_lib.addImport("llama", llama_mod);

    const infer_root = b.createModule(.{
        .root_source_file = b.path("infer/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    infer_root.addImport("cbor", cbor_mod);
    infer_root.addImport("log", log_mod);
    infer_root.addImport("infer", infer_lib);
    infer_root.addImport("llama", llama_mod);

    const infer_exe = b.addExecutable(.{
        .name = "dis-infer",
        .root_module = infer_root,
    });
    b.installArtifact(infer_exe);

    const infer_step = b.step("infer", "Build dis-infer");
    infer_step.dependOn(&b.addInstallArtifact(infer_exe, .{}).step);

    const run_infer = b.addRunArtifact(infer_exe);
    run_infer.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_infer.addArgs(args);
    const run_infer_step = b.step("run-infer", "Run dis-infer");
    run_infer_step.dependOn(&run_infer.step);

    // ── dis-infer-smoke (dev tool) ──────────────────────────────────
    const smoke_root = b.createModule(.{
        .root_source_file = b.path("infer/smoke/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_root.addImport("infer", infer_lib);

    const smoke_exe = b.addExecutable(.{
        .name = "dis-infer-smoke",
        .root_module = smoke_root,
    });
    const smoke_step = b.step("smoke", "Build the infer smoke client");
    smoke_step.dependOn(&b.addInstallArtifact(smoke_exe, .{}).step);

    // ── Tests ───────────────────────────────────────────────────────
    const engine_tests_root = b.createModule(.{
        .root_source_file = b.path("engine/src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_tests_root.addImport("cbor", cbor_mod);
    engine_tests_root.addImport("log", log_mod);
    const engine_tests = b.addTest(.{ .root_module = engine_tests_root });
    const run_engine_tests = b.addRunArtifact(engine_tests);
    const engine_test_step = b.step("test-engine", "Run engine unit tests");
    engine_test_step.dependOn(&run_engine_tests.step);

    const infer_tests_root = b.createModule(.{
        .root_source_file = b.path("infer/src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    infer_tests_root.addImport("cbor", cbor_mod);
    infer_tests_root.addImport("log", log_mod);
    infer_tests_root.addImport("llama", llama_mod);
    const infer_tests = b.addTest(.{ .root_module = infer_tests_root });
    const run_infer_tests = b.addRunArtifact(infer_tests);
    const infer_test_step = b.step("test-infer", "Run infer unit tests");
    infer_test_step.dependOn(&run_infer_tests.step);

    const test_step = b.step("test", "Run ALL unit tests");
    test_step.dependOn(&run_engine_tests.step);
    test_step.dependOn(&run_infer_tests.step);

    // Default `zig build` installs all three artifacts so `zig-out/bin`
    // has a clean shape after one invocation.
    b.getInstallStep().dependOn(&b.addInstallArtifact(smoke_exe, .{}).step);
}
