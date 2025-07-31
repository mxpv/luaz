const std = @import("std");
const assert = std.debug.assert;

const LazyPath = std.Build.LazyPath;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const flags = &.{
        "-DLUA_API=extern\"C\"",
        "-DLUACODEGEN_API=extern\"C\"",
        "-DLUACODE_API=extern\"C\"",
    };

    // All build steps
    const steps = .{
        .@"test" = b.step("test", "Run unit tests"),
        .docs = b.step("docs", "Install docs"),
        .check_fmt = b.step("check-fmt", "Check formatting"),
        // Luau tools
        .luau_compile = b.step("luau-compile", "Run Luau compiler"),
    };

    // Luau VM lib
    const luau_vm = blk: {
        const mod = b.createModule(.{ .target = target, .optimize = optimize });

        addSrcFiles(b, mod, "luau/VM/src", flags) catch @panic("Failed to add source files");

        mod.addCMacro("LUA_USE_LONGJMP", "1");

        mod.addIncludePath(b.path("luau/VM/include"));
        mod.addIncludePath(b.path("luau/VM/src"));
        mod.addIncludePath(b.path("luau/Common/include"));

        const lib = b.addLibrary(.{ .name = "luau_vm", .root_module = mod, .linkage = .static });

        lib.installHeadersDirectory(b.path("luau/VM/include"), "", .{});
        lib.linkLibCpp();

        b.installArtifact(lib);

        break :blk lib;
    };

    // Luau CodeGen lib
    const luau_codegen = blk: {
        const mod = b.createModule(.{ .target = target, .optimize = optimize });

        addSrcFiles(b, mod, "luau/CodeGen/src", flags) catch @panic("Failed to add CodeGen source files");

        mod.addIncludePath(b.path("luau/CodeGen/include"));
        mod.addIncludePath(b.path("luau/Common/include"));
        mod.addIncludePath(b.path("luau/VM/src"));

        const lib = b.addLibrary(.{ .name = "luau_codegen", .root_module = mod, .linkage = .static });

        lib.installHeader(b.path("luau/CodeGen/include/luacodegen.h"), "luacodegen.h");

        lib.linkLibCpp();
        lib.linkLibrary(luau_vm);

        b.installArtifact(lib);

        break :blk lib;
    };

    // Luau compiler + AST libs
    const luau_compiler = blk: {
        const mod = b.createModule(.{ .target = target, .optimize = optimize });

        addSrcFiles(b, mod, "luau/Compiler/src", flags) catch @panic("Failed to add CodeGen source files");
        addSrcFiles(b, mod, "luau/Ast/src", flags) catch @panic("");

        mod.addCMacro("LUA_USE_LONGJMP", "1");

        mod.addIncludePath(b.path("luau/Common/include"));
        mod.addIncludePath(b.path("luau/Ast/include"));
        mod.addIncludePath(b.path("luau/Compiler/include"));
        mod.addIncludePath(b.path("luau/Compiler/src"));

        const lib = b.addLibrary(.{ .name = "luau_compiler", .root_module = mod, .linkage = .static });

        lib.installHeader(b.path("luau/Compiler/include/luacode.h"), "luacode.h");
        lib.linkLibCpp();

        b.installArtifact(lib);

        break :blk lib;
    };

    // Luau compiler binary
    {
        const exe = b.addExecutable(.{ .name = "luau-compile", .target = target, .optimize = optimize });

        exe.addCSourceFiles(.{
            .files = &[_][]const u8{
                "luau/CLI/src/Compile.cpp",
                "luau/CLI/src/FileUtils.cpp",
                "luau/CLI/src/Flags.cpp",
            },
            .flags = flags,
        });

        exe.addIncludePath(b.path("luau/Common/include"));
        exe.addIncludePath(b.path("luau/CLI/include"));
        exe.addIncludePath(b.path("luau/CodeGen/include"));
        exe.addIncludePath(b.path("luau/Compiler/include"));
        exe.addIncludePath(b.path("luau/Ast/include"));

        exe.linkLibrary(luau_vm);
        exe.linkLibrary(luau_codegen);
        exe.linkLibrary(luau_compiler);

        const run_binary = b.addRunArtifact(exe);

        if (b.args) |args| {
            run_binary.addArgs(args);
        }

        steps.luau_compile.dependOn(&run_binary.step);
    }

    // Main module
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });

        mod.linkLibrary(luau_vm);

        // TODO: Make these optional
        mod.linkLibrary(luau_codegen);
        mod.linkLibrary(luau_compiler);

        const lib = b.addLibrary(.{
            .name = "luaz",
            .root_module = mod,
            .linkage = .static,
        });

        b.installArtifact(lib);

        // Docs
        const install_docs = b.addInstallDirectory(.{
            .source_dir = lib.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        steps.docs.dependOn(&install_docs.step);
    }

    // Tests
    {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/unit_tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        unit_tests.linkLibrary(luau_vm);
        unit_tests.linkLibrary(luau_codegen);
        unit_tests.linkLibrary(luau_compiler);
        unit_tests.linkLibCpp();

        const run_tests = b.addRunArtifact(unit_tests);
        steps.@"test".dependOn(&run_tests.step);
    }

    // zig build check-fmt
    {
        const run_fmt = b.addFmt(.{ .check = true, .paths = &.{"."} });

        steps.check_fmt.dependOn(&run_fmt.step);
    }
}

fn addSrcFiles(b: *std.Build, mod: *std.Build.Module, path: []const u8, flags: []const []const u8) !void {
    const extensions = [_][]const u8{ ".cpp", ".c" };

    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    var files = std.ArrayList([]const u8).init(b.allocator);

    while (try walker.next()) |entry| {
        const ext = std.fs.path.extension(entry.basename);
        const include = for (extensions) |e| {
            if (std.mem.eql(u8, ext, e))
                break true;
        } else false;

        if (include and entry.kind == .file) {
            const entry_path = b.pathJoin(&[_][]const u8{ path, entry.path });
            try files.append(entry_path);
        }
    }

    mod.addCSourceFiles(.{
        .files = files.items,
        .flags = flags,
    });
}
