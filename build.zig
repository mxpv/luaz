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
        .vector_size = b.option(u8, "vector-size", "Luau vector size (3 or 4, default 4)") orelse 4,
    };

    // Validate vector size
    if (opts.vector_size != 3 and opts.vector_size != 4) {
        std.log.err("Invalid vector size: {}. Must be either 3 or 4", .{opts.vector_size});
        return error.InvalidVectorSize;
    }

    const luau_dep = b.dependency("luau", .{});

    // Luau VM lib
    const luau_vm = blk: {
        const mod = b.createModule(.{ .target = target, .optimize = optimize });

        try addSrcFiles(b, mod, luau_dep, "VM/src", flags);

        mod.addCMacro("LUA_USE_LONGJMP", "1");
        mod.addCMacro("LUA_VECTOR_SIZE", b.fmt("{d}", .{opts.vector_size}));

        mod.addIncludePath(luau_dep.path("VM/include"));
        mod.addIncludePath(luau_dep.path("VM/src"));
        mod.addIncludePath(luau_dep.path("Common/include"));

        const lib = b.addLibrary(.{ .name = "luau_vm", .root_module = mod, .linkage = .static });

        lib.installHeadersDirectory(luau_dep.path("VM/include"), "", .{});
        lib.linkLibCpp();

        b.installArtifact(lib);

        steps.luau_vm.dependOn(&lib.step);

        break :blk lib;
    };

    // Luau CodeGen lib
    const luau_codegen = blk: {
        const mod = b.createModule(.{ .target = target, .optimize = optimize });

        try addSrcFiles(b, mod, luau_dep, "CodeGen/src", flags);

        mod.addCMacro("LUA_VECTOR_SIZE", b.fmt("{d}", .{opts.vector_size}));
        mod.addIncludePath(luau_dep.path("CodeGen/include"));
        mod.addIncludePath(luau_dep.path("Common/include"));
        mod.addIncludePath(luau_dep.path("VM/src"));

        const lib = b.addLibrary(.{ .name = "luau_codegen", .root_module = mod, .linkage = .static });

        lib.installHeader(luau_dep.path("CodeGen/include/luacodegen.h"), "luacodegen.h");

        lib.linkLibCpp();
        lib.linkLibrary(luau_vm);

        b.installArtifact(lib);

        steps.luau_codegen.dependOn(&lib.step);

        break :blk lib;
    };

    // Luau compiler lib
    const luau_compiler = blk: {
        const mod = b.createModule(.{ .target = target, .optimize = optimize });

        try addSrcFiles(b, mod, luau_dep, "Compiler/src", flags);
        try addSrcFiles(b, mod, luau_dep, "Ast/src", flags);

        mod.addCMacro("LUA_USE_LONGJMP", "1");

        mod.addIncludePath(luau_dep.path("Common/include"));
        mod.addIncludePath(luau_dep.path("Ast/include"));
        mod.addIncludePath(luau_dep.path("Compiler/include"));
        mod.addIncludePath(luau_dep.path("Compiler/src"));

        const lib = b.addLibrary(.{ .name = "luau_compiler", .root_module = mod, .linkage = .static });

        lib.installHeader(luau_dep.path("Compiler/include/luacode.h"), "luacode.h");
        lib.linkLibCpp();

        b.installArtifact(lib);

        break :blk lib;
    };

    // Luau compiler binary
    {
        const mod = b.createModule(.{ .target = target, .optimize = optimize });

        mod.addCSourceFiles(.{
            .root = luau_dep.path("."),
            .files = &.{
                "CLI/src/Compile.cpp",
                "CLI/src/FileUtils.cpp",
                "CLI/src/Flags.cpp",
            },
            .flags = flags,
        });

        addLuauIncludes(luau_dep, mod);

        mod.linkLibrary(luau_vm);
        mod.linkLibrary(luau_codegen);
        mod.linkLibrary(luau_compiler);

        const exe = b.addExecutable(.{
            .name = "luau-compile",
            .root_module = mod,
        });

        const run = b.addRunArtifact(exe);

        if (b.args) |args| {
            run.addArgs(args);
        }

        steps.luau_compile.dependOn(&run.step);
    }

    // Luau analyze binary
    {
        const mod = b.createModule(.{ .target = target, .optimize = optimize });

        try addSrcFiles(b, mod, luau_dep, "Analysis/src", flags);
        try addSrcFiles(b, mod, luau_dep, "EqSat/src", flags);
        try addSrcFiles(b, mod, luau_dep, "Config/src", flags);
        try addSrcFiles(b, mod, luau_dep, "Require/Navigator/src", flags);

        mod.addCSourceFiles(.{
            .root = luau_dep.path("."),
            .files = &.{
                // Analyze CLI
                "CLI/src/Analyze.cpp",
                "CLI/src/AnalyzeRequirer.cpp",
                "CLI/src/FileUtils.cpp",
                "CLI/src/Flags.cpp",
                "CLI/src/VfsNavigator.cpp",
            },
            .flags = flags,
        });

        addLuauIncludes(luau_dep, mod);

        mod.linkLibrary(luau_vm);
        mod.linkLibrary(luau_compiler);

        const exe = b.addExecutable(.{
            .name = "luau-analyze",
            .root_module = mod,
        });

        exe.linkLibCpp();

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
        mod.addCMacro("LUA_VECTOR_SIZE", b.fmt("{d}", .{opts.vector_size}));
        mod.addIncludePath(luau_dep.path("VM/include"));
        mod.addIncludePath(luau_dep.path("Common/include"));
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
        unit_tests.root_module.addCMacro("LUA_VECTOR_SIZE", b.fmt("{d}", .{opts.vector_size}));
        unit_tests.root_module.addIncludePath(luau_dep.path("VM/include"));
        unit_tests.root_module.addIncludePath(luau_dep.path("Common/include"));
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
        const mod = b.createModule(.{
            .root_source_file = b.path("examples/guided_tour.zig"),
            .target = target,
            .optimize = optimize,
        });

        mod.addImport("luaz", b.modules.get("luaz").?);

        const guided_tour = b.addExecutable(.{
            .name = "guided-tour",
            .root_module = mod,
        });

        const run_guided_tour = b.addRunArtifact(guided_tour);
        if (b.args) |args| {
            run_guided_tour.addArgs(args);
        }

        const guided_tour_step = b.step("guided-tour", "Run the guided tour example");
        guided_tour_step.dependOn(&run_guided_tour.step);
    }
}

fn addSrcFiles(
    b: *std.Build,
    mod: *std.Build.Module,
    dep: *std.Build.Dependency,
    dir_path: []const u8,
    flags: []const []const u8,
) !void {
    const extensions = [_][]const u8{ ".cpp", ".c" };

    const abs_path = dep.path(dir_path).getPath(b);
    var dir = try std.fs.openDirAbsolute(abs_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;

    while (try walker.next()) |entry| {
        const ext = std.fs.path.extension(entry.basename);
        const include = for (extensions) |e| {
            if (std.mem.eql(u8, ext, e))
                break true;
        } else false;

        if (include and entry.kind == .file) {
            try files.append(b.allocator, b.dupe(entry.path));
        }
    }

    mod.addCSourceFiles(.{
        .root = dep.path(dir_path),
        .files = files.items,
        .flags = flags,
    });
}

fn addLuauIncludes(dep: *std.Build.Dependency, mod: *std.Build.Module) void {
    mod.addIncludePath(dep.path("Common/include"));

    mod.addIncludePath(dep.path("VM/include"));
    mod.addIncludePath(dep.path("Runtime/include"));

    mod.addIncludePath(dep.path("Analysis/include"));
    mod.addIncludePath(dep.path("Config/include"));

    mod.addIncludePath(dep.path("EqSat/include"));
    mod.addIncludePath(dep.path("Navigator/include"));

    mod.addIncludePath(dep.path("Ast/include"));
    mod.addIncludePath(dep.path("Compiler/include"));
    mod.addIncludePath(dep.path("CodeGen/include"));

    mod.addIncludePath(dep.path("Require/Navigator/include"));
    mod.addIncludePath(dep.path("Require/Runtime/include"));

    mod.addIncludePath(dep.path("CLI/include"));
}
