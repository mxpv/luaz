const std = @import("std");
const assert = std.debug.assert;

const LazyPath = std.Build.LazyPath;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const luaz_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // VM
    const files = findSrcFiles(b, "luau/VM/src/") catch @panic("Failed to find source files");
    luaz_mod.addCSourceFiles(.{ .files = files.items, .flags = &[_][]const u8{"-DLUA_API=extern\"C\""} });

    luaz_mod.addCMacro("LUA_USE_LONGJMP", "1");

    luaz_mod.addIncludePath(b.path("luau/VM/include"));
    luaz_mod.addIncludePath(b.path("luau/VM/src"));
    luaz_mod.addIncludePath(b.path("luau/Common/include"));

    // Tests

    const lib_unit_tests = b.addTest(.{ .root_module = luaz_mod });
    lib_unit_tests.linkLibCpp();

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

fn findSrcFiles(b: *std.Build, path: []const u8) !std.ArrayList([]const u8) {
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

    return files;
}
