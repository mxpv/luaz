const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("luacode.h");
});

const Error = @import("root.zig").Error;

/// Luau compiler interface for compiling Lua source code to bytecode.
pub const Compiler = struct {
    /// Result of compilation operation containing either bytecode or error message.
    pub const Result = union(enum) {
        /// Compiled Luau bytecode.
        ok: []const u8,
        /// Result contains the error message.
        err: []const u8,

        /// Luau uses `malloc` to allocate the returning blob with either bytecode or error message.
        /// Either way, must use `C.free` to let it go.
        pub fn deinit(self: Result) void {
            switch (self) {
                .ok => |bytecode| c.free(@constCast(bytecode.ptr)),
                .err => |message| c.free(@constCast(message.ptr)),
            }
        }
    };

    /// Compilation options for controlling Luau compiler behavior.
    pub const Opts = struct {
        /// Optimization level.
        ///
        /// 0 - no optimization
        /// 1 - baseline optimization level that doesn't prevent debuggability
        /// 2 - includes optimizations that harm debuggability such as inlining
        optLevel: u8 = 1,

        /// Debug level.
        ///
        /// 0 - no debugging support
        /// 1 - line info & function names only; sufficient for backtraces
        /// 2 - full debug info with local & upvalue names; necessary for debugger
        dbgLevel: u8 = 1,

        /// Type information is used to guide native code generation decisions
        /// information includes testable types for function arguments, locals, upvalues and some temporaries
        /// 0 - generate for native modules
        /// 1 - generate for all modules
        typeInfoLevel: u8 = 0,

        /// Coverage support level.
        ///
        /// 0 - no code coverage support
        /// 1 - statement coverage
        /// 2 - statement and expression coverage (verbose)
        coverageLevel: u8 = 0,
    };

    /// Compiles Lua source code to bytecode using the Luau compiler.
    /// Returns either compiled bytecode or an error message.
    /// In both cases, memory must be freed using Result.deinit().
    pub fn compile(source: []const u8, opts: Opts) !Result {
        var options = c.lua_CompileOptions{
            .optimizationLevel = opts.optLevel,
            .debugLevel = opts.dbgLevel,
            .typeInfoLevel = opts.typeInfoLevel,
            .coverageLevel = opts.coverageLevel,
        };

        var sz: usize = 0;
        const ptr = c.luau_compile(
            source.ptr,
            source.len,
            &options,
            &sz,
        );

        if (ptr == null or sz == 0) {
            return Error.OutOfMemory;
        }

        const blob = ptr[0..sz];

        // When source compilation fails, the resulting bytecode contains the encoded error.
        // 0 acts as a special marker for error bytecode.
        // See https://github.com/luau-lang/luau/blob/8fe64db609ccbffb0abb7507c7ecef8c88327ef3/Compiler/src/BytecodeBuilder.cpp#L1212
        return if (blob[0] == 0) .{ .err = blob } else .{ .ok = blob };
    }
};

test "Compile Luau code" {
    const result = try Compiler.compile("return 1 + 1", .{ .optLevel = 2 });
    defer result.deinit();

    try std.testing.expect(result == .ok);

    const bytecode = result.ok;
    try std.testing.expect(bytecode.len > 0);
}

test "Compile error" {
    const result = try Compiler.compile("return 1 + '", .{});
    defer result.deinit();

    // Assert that compilation failed
    try std.testing.expect(result == .err);

    const message = result.err;
    const expected_error = ":1: Malformed string; did you forget to finish it?";

    // Check that the error message contains the expected text
    try std.testing.expect(std.mem.indexOf(u8, message, expected_error) != null);
}
