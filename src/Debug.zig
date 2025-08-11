//! Debug functionality for Luau scripts.
//!
//! This module provides debugging support for Luau scripts, including breakpoints,
//! single-stepping, and execution interruption. The debug system uses a callback-based
//! approach where the VM notifies your application when debug events occur.
//!
//! ## Basic Usage
//!
//! 1. Set up debug callbacks using `lua.setCallbacks()`:
//! ```zig
//! const DebugCallbacks = struct {
//!     pub fn debugbreak(self: *@This(), debug: *Debug, ar: Debug.Info) void {
//!         std.log.info("Hit breakpoint at line {}", .{ar.current_line});
//!         // Call debugBreak() to actually interrupt execution
//!         debug.debugBreak();
//!     }
//! };
//!
//! var callbacks = DebugCallbacks{};
//! lua.setCallbacks(&callbacks);
//! ```
//!
//! 2. Set breakpoints on functions using `function.setBreakpoint(line)`:
//! ```zig
//! // Lua code to debug
//! const code =
//!     \\function myFunction()
//!     \\    local x = 10
//!     \\    return x + 5  -- This is line 3
//!     \\end
//! ;
//!
//! _ = try lua.eval(code, .{}, void);
//! const func = try lua.globals().get("myFunction", Function);
//! defer func.deinit();
//!
//! // Set breakpoint on line 3 of the function
//! const actual_line = try func.setBreakpoint(3, true);
//! ```
//!
//! 3. Handle interrupted execution:
//! ```zig
//! const result = func.call(.{}, i32) catch |err| switch (err) {
//!     error.Break => {
//!         // Execution was interrupted at breakpoint
//!         // Can examine state, variables, etc.
//!
//!         // Resume execution by calling the function again
//!         return func.call(.{}, i32);
//!     },
//!     else => return err,
//! };
//! ```
//!
//! ## Debug Flow
//!
//! The debugging process follows this flow:
//! 1. Breakpoint hit → VM calls your `debugbreak` callback
//! 2. In callback → Call `debug.debugBreak()` to interrupt execution
//! 3. VM interrupts → Sets internal status to LUA_BREAK
//! 4. Function returns → `error.Break` to your application code
//! 5. Resume execution → Call the function again to continue from where it left off
//!
//! ## Key Concepts
//!
//! - Breakpoints are notifications: Setting breakpoints with `function.setBreakpoint()` only triggers
//!   the callback - it doesn't automatically stop execution.
//! - debugBreak() stops execution: You must call `debug.debugBreak()` within your
//!   callback to actually interrupt and return control to your application.
//! - Resumption: After `error.Break`, call the same function again to resume execution.
//! - Debug info limitations: Only `current_line` and `userdata` fields are populated
//!   in debug callbacks. Other fields contain garbage values.
//!
//! ## Advanced Features
//!
//! - Single stepping: Use `debug.setSingleStep(true)` and the `debugstep` callback
//! - Thread interruption: Use `debuginterrupt` callback for coroutine debugging
//! - Function breakpoints: Use `function.setBreakpoint(line)` to set breakpoints on specific functions
//! - Conditional breakpoints: Only call `debugBreak()` when certain conditions are met
//!
//! ## Debug Information
//!
//! The `Info` struct contains information about the current execution context,
//! but note that most fields are only populated during `lua_getinfo()` calls,
//! not during debug hook callbacks.

const std = @import("std");
const State = @import("State.zig");

state: *State,

const Self = @This();

pub fn init(state: *State) Self {
    return Self{ .state = state };
}

/// Debug information for a function activation record
pub const Info = struct {
    /// Function name (may be null if not available)
    name: ?[]const u8,
    /// Function type: "Lua", "C", "main", or "tail"
    what: []const u8,
    /// Source file name
    source: []const u8,
    /// Short source name for display
    short_src: []const u8,
    /// Line where function was defined
    line_defined: i32,
    /// Current line being executed
    current_line: i32,
    /// Number of upvalues
    upvalue_count: u8,
    /// Number of parameters
    param_count: u8,
    /// Whether function accepts variable arguments
    is_vararg: bool,
    /// Optional user data (for debuginterrupt, contains the interrupted thread state)
    userdata: ?*anyopaque,

    /// Creates an Info struct from a C lua_Debug pointer
    ///
    /// NOTE: Luau debug hooks (debugbreak, debugstep, debuginterrupt) only populate
    /// the `currentline` and `userdata` fields of lua_Debug. Other fields like `what`, `source`,
    /// `name`, `linedefined`, etc. are left uninitialized (contain garbage/null pointers)
    /// because the VM doesn't call lua_getinfo() during debug callbacks.
    ///
    /// See: https://github.com/luau-lang/luau/blob/8863bfc950d52e9e7b468354d353ca43623da4f6/VM/src/lvmexecute.cpp#L165
    /// The luau_callhook function only sets ar.currentline and ar.userdata before calling the hook.
    ///
    /// To get full debug information, you would need to manually call lua_getinfo() with
    /// appropriate flags like "slu" within your callback, but this requires access to the
    /// function on the stack which is more complex.
    pub fn fromC(c_debug: *State.Debug) Info {
        return Info{
            .name = null,
            .what = "",
            .source = "",
            .short_src = "",
            .line_defined = c_debug.linedefined,
            .current_line = c_debug.currentline,
            .upvalue_count = c_debug.nupvals,
            .param_count = c_debug.nparams,
            .is_vararg = c_debug.isvararg != 0,
            .userdata = c_debug.userdata,
        };
    }

    /// Gets the interrupted thread from debuginterrupt callback userdata.
    /// Returns null if userdata is null or not a valid thread state.
    /// Only valid when called from debuginterrupt callback.
    pub fn getInterruptedThread(self: Info) ?State {
        if (self.userdata) |data| {
            const lua_state: State.LuaState = @ptrCast(@alignCast(data));
            return State{ .lua = lua_state };
        }
        return null;
    }
};

/// Enables or disables single-step debugging mode.
///
/// When single-step mode is enabled, the `debugstep` callback will be called
/// after every instruction in Lua code execution. This allows for precise
/// step-by-step debugging of Lua code.
///
/// Requirements:
/// - `debugstep` callback should be set using `setCallbacks()` to handle step events
///
/// Performance Note:
/// Single-step mode has significant performance impact since it triggers a callback
/// after every instruction. Use only when debugging is needed.
///
/// Example:
/// ```zig
/// const DebugCallbacks = struct {
///     step_count: u32 = 0,
///
///     pub fn debugstep(self: *@This(), debug: *Debug, ar: Debug.Info) void {
///         self.step_count += 1;
///         std.log.info("Step {} at line {}", .{ self.step_count, ar.current_line });
///     }
/// };
///
/// var callbacks = DebugCallbacks{};
/// lua.setCallbacks(&callbacks);
///
/// lua.debug.setSingleStep(true);
/// _ = try lua.eval("local x = 1; local y = 2; return x + y", .{}, i32);
/// // debugstep callback will be called for each instruction
///
/// lua.debug.setSingleStep(false); // Disable when done debugging
/// ```
pub fn setSingleStep(self: Self, enabled: bool) void {
    self.state.singleStep(enabled);
}

/// Interrupt thread execution during debug callbacks.
///
/// This method should be called from within debug callbacks (debugbreak, debugstep, debuginterrupt)
/// to interrupt the currently executing Lua thread and return control to your application.
/// After calling this method, the function that was executing will return with `error.Break`.
///
/// Note: Breakpoints set with `breakpoint(line)` in Lua code only trigger debug callbacks - they
/// don't automatically interrupt execution. You must call `debugBreak()` within your callback
/// to actually stop execution and return control to your application.
///
/// Typical debugging flow:
/// 1. Breakpoint hits → VM calls your debugbreak callback
/// 2. In callback → call `debugBreak()` to interrupt execution
/// 3. VM interrupts → Sets internal status to LUA_BREAK
/// 4. Function returns → `error.Break` to your application code
/// 5. Resume execution → Call the function again to continue from where it left off
///
/// Example:
/// ```zig
/// const DebugCallbacks = struct {
///     pub fn debugbreak(self: *@This(), debug: *Debug, ar: Debug.Info) void {
///         std.log.info("Hit breakpoint at line {}", .{ar.current_line});
///         debug.debugBreak();
///     }
/// };
///
/// var callbacks = DebugCallbacks{};
/// lua.setCallbacks(&callbacks);
///
/// const result = func.call(.{}, i32) catch |err| switch (err) {
///     error.Break => {
///         // Handle interrupted execution
///         return func.call(.{}, i32); // Resume
///     },
///     else => return err,
/// };
/// ```
///
pub fn debugBreak(self: Self) void {
    self.state.break_();
}

/// Get a stack trace for debugging purposes.
///
/// Returns a null-terminated string containing a formatted representation of the current
/// call stack. The trace includes function names, source locations, and line numbers
/// when available. This function is useful for error reporting, crash analysis,
/// or debugging runtime issues.
///
/// Performance Considerations:
/// - Uses a static internal buffer (4096 bytes) that is NOT thread-safe
/// - Multiple calls overwrite the previous result
/// - Shows only first 10 and last 10 frames if stack exceeds 20 frames
/// - Intended for debugging and development use only
///
/// Thread Safety:
/// This function is NOT thread-safe. The returned string points to a static buffer
/// that is shared across all Lua states in the process.
///
/// Usage:
/// - For debugging only: This function is intended for development and debugging,
///   not for production error handling or logging
/// - Immediate use: Copy or use the returned string immediately, as subsequent
///   calls will overwrite the buffer
/// - Single-threaded: Only use in single-threaded applications or with appropriate
///   synchronization
///
/// Example:
/// ```zig
/// const result = lua.eval(code, .{}, i32) catch |err| {
///     std.debug.print("Error: {}\n", .{err});
///     std.debug.print("Stack trace:\n{s}\n", .{lua.debug.debugTrace()});
///     return err;
/// };
/// ```
pub fn debugTrace(self: Self) [:0]const u8 {
    return self.state.debugTrace();
}

// Tests for debug functionality
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Lua = @import("lua.zig").Lua;

test "debugTrace shows function names in call stack" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Set up breakpoint callback to capture trace when breakpoint is hit
    const BreakpointCapture = struct {
        var captured_trace: [:0]const u8 = "";
        var breakpoint_hit: bool = false;

        pub fn debugbreak(self: *@This(), debug: *Self, ar: Info) void {
            _ = self;
            _ = ar;
            if (!breakpoint_hit) {
                breakpoint_hit = true;
                captured_trace = debug.debugTrace();
            }
            // Don't actually break - just capture the trace
        }
    };

    var capture = BreakpointCapture{};
    lua.setCallbacks(&capture);

    // Create nested functions
    const code =
        \\function innerFunc()
        \\    return 42  -- Breakpoint will be set on this line
        \\end
        \\
        \\function middleFunc()
        \\    return innerFunc()
        \\end
        \\
        \\function outerFunc()
        \\    return middleFunc()
        \\end
    ;

    _ = try lua.eval(code, .{}, void);

    // Get the innerFunc and set a breakpoint
    const func = try lua.globals().get("innerFunc", Lua.Function);
    defer func.?.deinit();
    _ = try func.?.setBreakpoint(2, true); // Line 2: return 42

    // Call the nested functions - this should hit the breakpoint
    const result = try lua.eval("return outerFunc()", .{}, i32);
    try expectEqual(result.ok.?, 42);

    // Verify we captured a trace and it contains our function names
    try expect(BreakpointCapture.breakpoint_hit);
    const trace = BreakpointCapture.captured_trace;
    try expect(trace.len > 0);

    // The trace should contain all three function names in the call stack
    try expect(std.mem.indexOf(u8, trace, "function outerFunc") != null);
    try expect(std.mem.indexOf(u8, trace, "function middleFunc") != null);
    try expect(std.mem.indexOf(u8, trace, "function innerFunc") != null);
}

test "breakpoint and single step debugging with callbacks" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const DebugCallbacks = struct {
        break_hits: u32 = 0,
        step_hits: u32 = 0,

        pub fn debugbreak(self: *@This(), debug: *Self, ar: Info) void {
            _ = debug;
            std.debug.assert(ar.current_line == 5);
            self.break_hits += 1;
        }

        pub fn debugstep(self: *@This(), debug: *Self, ar: Info) void {
            _ = debug;
            std.debug.assert(self.step_hits == 0); // Only expecting 1 step
            std.debug.assert(ar.current_line == 5);
            self.step_hits += 1;
        }
    };

    var callbacks = DebugCallbacks{};

    // Create a multi-step function
    _ = try lua.eval(
        \\function test_func()
        \\    local x = 10     -- line 2
        \\    local y = 20     -- line 3
        \\    local z = x + y  -- line 4
        \\    return z * 2     -- line 5
        \\end
    , .{}, void);

    // Get function reference
    const func = try lua.globals().get("test_func", Lua.Function);
    try expect(func != null);
    defer func.?.deinit();

    const breakpoint_line = try func.?.setBreakpoint(4, true);
    try expectEqual(breakpoint_line, 5);

    lua.debug().setSingleStep(true);
    lua.setCallbacks(&callbacks);

    const result = try func.?.call(.{}, i32);

    try expectEqual(result.ok, 60);
    try expectEqual(callbacks.break_hits, 1);
    try expectEqual(callbacks.step_hits, 1);
}

test "coroutine debug break" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const DebugBreakCallbacks = struct {
        call_count: u32 = 0,

        pub fn debugbreak(self: *@This(), debug: *Self, ar: Info) void {
            _ = ar;
            self.call_count += 1;
            if (self.call_count == 1) {
                debug.debugBreak();
            }
        }
    };

    var callbacks = DebugBreakCallbacks{};
    lua.setCallbacks(&callbacks);

    const thread = lua.createThread();
    defer thread.deinit();

    _ = try thread.eval(
        \\function test_func()
        \\    return 42
        \\end
    , .{}, void);

    const func = try thread.globals().get("test_func", Lua.Function);
    defer func.?.deinit();

    _ = try func.?.setBreakpoint(2, true);

    const first_result = try func.?.call(.{}, i32);
    try expectEqual(first_result, .debugBreak);

    try expectEqual(thread.status(), .normal);

    // Call function again - should complete and return result
    const second_result = try func.?.call(.{}, i32);
    try expectEqual(second_result.ok, 42);

    // Assert debugbreak callback was called exactly twice
    try expectEqual(callbacks.call_count, 2);
}
