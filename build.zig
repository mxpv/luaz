const std = @import("std");

pub fn build(b: *std.Build) !void {
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
        .luau_analysis = b.step("luau-analyze", "Run Luau analyze"),
        // Luau libs
        .luau_vm = b.step("luau-vm", "Build Luau VM lib"),
        .luau_codegen = b.step("luau-codegen", "Build Luau codegen lib"),
    };

    const opts = .{
        .cover = b.option(bool, "coverage", "Generate test coverage (requires kcov)") orelse false,
    };

    // Luau VM lib
    const luau_vm = blk: {
        const mod = b.createModule(.{ .target = target, .optimize = optimize });

        try addSrcFiles(b, mod, "luau/VM/src", flags);

        mod.addCMacro("LUA_USE_LONGJMP", "1");

        mod.addIncludePath(b.path("luau/VM/include"));
        mod.addIncludePath(b.path("luau/VM/src"));
        mod.addIncludePath(b.path("luau/Common/include"));

        const lib = b.addLibrary(.{ .name = "luau_vm", .root_module = mod, .linkage = .static });

        lib.installHeadersDirectory(b.path("luau/VM/include"), "", .{});
        lib.linkLibCpp();

        b.installArtifact(lib);

        steps.luau_vm.dependOn(&lib.step);

        break :blk lib;
    };

    // Luau CodeGen lib
    const luau_codegen = blk: {
        const mod = b.createModule(.{ .target = target, .optimize = optimize });

        try addSrcFiles(b, mod, "luau/CodeGen/src", flags);

        mod.addIncludePath(b.path("luau/CodeGen/include"));
        mod.addIncludePath(b.path("luau/Common/include"));
        mod.addIncludePath(b.path("luau/VM/src"));

        const lib = b.addLibrary(.{ .name = "luau_codegen", .root_module = mod, .linkage = .static });

        lib.installHeader(b.path("luau/CodeGen/include/luacodegen.h"), "luacodegen.h");

        lib.linkLibCpp();
        lib.linkLibrary(luau_vm);

        b.installArtifact(lib);

        steps.luau_codegen.dependOn(&lib.step);

        break :blk lib;
    };

    // Luau compiler lib
    const luau_compiler = blk: {
        const mod = b.createModule(.{ .target = target, .optimize = optimize });

        try addSrcFiles(b, mod, "luau/Compiler/src", flags);
        try addSrcFiles(b, mod, "luau/Ast/src", flags);

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

        addLuauIncludes(b, exe.root_module);

        exe.linkLibrary(luau_vm);
        exe.linkLibrary(luau_codegen);
        exe.linkLibrary(luau_compiler);

        const run = b.addRunArtifact(exe);

        if (b.args) |args| {
            run.addArgs(args);
        }

        steps.luau_compile.dependOn(&run.step);
    }

    // Luau analyze binary
    {
        const exe = b.addExecutable(.{ .name = "luau-analyze", .target = target, .optimize = optimize });

        try addSrcFiles(b, exe.root_module, "luau/Analysis/src", flags);
        try addSrcFiles(b, exe.root_module, "luau/EqSat/src", flags);
        try addSrcFiles(b, exe.root_module, "luau/Config/src", flags);
        try addSrcFiles(b, exe.root_module, "luau/Require/Navigator/src", flags);

        exe.addCSourceFiles(.{
            .files = &[_][]const u8{
                // Analyze CLI
                "luau/CLI/src/Analyze.cpp",
                "luau/CLI/src/AnalyzeRequirer.cpp",
                "luau/CLI/src/FileUtils.cpp",
                "luau/CLI/src/Flags.cpp",
                "luau/CLI/src/VfsNavigator.cpp",
            },
            .flags = flags,
        });

        addLuauIncludes(b, exe.root_module);

        exe.linkLibCpp();
        exe.linkLibrary(luau_vm);
        exe.linkLibrary(luau_compiler);

        const run = b.addRunArtifact(exe);
        if (b.args) |args| {
            run.addArgs(args);
        }

        steps.luau_analysis.dependOn(&run.step);
    }

    // Main module
    {
        const mod = b.addModule("luaz", .{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        });

        // Add C wrapper
        mod.addCSourceFile(.{
            .file = b.path("src/handler.cpp"),
            .flags = flags,
        });
        mod.addIncludePath(b.path("luau/VM/include"));
        mod.addIncludePath(b.path("luau/Common/include"));
        mod.addIncludePath(b.path("src"));

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
        b.getInstallStep().dependOn(&install_docs.step);
    }

    // zig build test
    {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        // Add C wrapper
        unit_tests.root_module.addCSourceFile(.{
            .file = b.path("src/handler.cpp"),
            .flags = flags,
        });
        unit_tests.root_module.addIncludePath(b.path("luau/VM/include"));
        unit_tests.root_module.addIncludePath(b.path("luau/Common/include"));
        unit_tests.root_module.addIncludePath(b.path("src"));

        // See https://zig.news/squeek502/code-coverage-for-zig-1dk1
        if (opts.cover) {
            unit_tests.setExecCmd(&[_]?[]const u8{
                "kcov",
                "--clean", // Don't accumulate data from multiple runs
                "--include-path=src/",
                b.pathJoin(&.{ b.install_path, "coverage" }),
                null,
            });
        }

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

    // Guided tour example
    {
        const guided_tour = b.addExecutable(.{
            .name = "guided_tour",
            .root_source_file = b.path("examples/guided_tour.zig"),
            .target = target,
            .optimize = optimize,
        });

        guided_tour.root_module.addImport("luaz", b.modules.get("luaz").?);

        const run_guided_tour = b.addRunArtifact(guided_tour);
        if (b.args) |args| {
            run_guided_tour.addArgs(args);
        }

        const guided_tour_step = b.step("guided-tour", "Run the guided tour example");
        guided_tour_step.dependOn(&run_guided_tour.step);
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

fn addLuauIncludes(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("luau/Common/include"));

    mod.addIncludePath(b.path("luau/VM/include"));
    mod.addIncludePath(b.path("luau/Runtime/include"));

    mod.addIncludePath(b.path("luau/Analysis/include"));
    mod.addIncludePath(b.path("luau/Config/include"));

    mod.addIncludePath(b.path("luau/EqSat/include"));
    mod.addIncludePath(b.path("luau/Navigator/include"));

    mod.addIncludePath(b.path("luau/Ast/include"));
    mod.addIncludePath(b.path("luau/Compiler/include"));
    mod.addIncludePath(b.path("luau/CodeGen/include"));

    mod.addIncludePath(b.path("luau/Require/Navigator/include"));
    mod.addIncludePath(b.path("luau/Require/Runtime/include"));

    mod.addIncludePath(b.path("luau/CLI/include"));
}
