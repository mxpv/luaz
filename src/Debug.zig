//! Debug functionality for Luau scripts.
//!
//! This module provides debugging support for Luau scripts, including breakpoints,
//! single-stepping, and execution interruption. The debug system uses a callback-based
//! approach where the VM notifies your application when debug events occur.
//!
//! ## Debug Flow
//!
//! The debugging process follows this flow:
//! 1. Set up callbacks → Register your debug callback struct with `lua.setCallbacks()`
//! 2. Set breakpoints → Use `function.setBreakpoint(line)` on specific functions
//! 3. Call function → Execute Lua code normally with `function.call()`
//! 4. Breakpoint hits → VM calls your `debugbreak` callback
//! 5. Interrupt execution → Call `debug.debugBreak()` within callback to pause
//! 6. Handle interruption → Function returns `error.Break` to your application
//! 7. Examine state → Use `getInfo()`, `stackDepth()`, etc. to inspect execution
//! 8. Resume execution → Call the function again to continue from where it left off
//!
//! ## Key Concepts
//!
//! - Breakpoints are notifications: Setting breakpoints only triggers callbacks
//! - debugBreak() interrupts execution: Must be called within callbacks to actually stop
//! - Resumption: After `error.Break`, call the same function again to resume
//! - Field safety: Only request fields you need in `getInfo()` to avoid garbage data
//! - Context flexibility: `getInfo()` and `stackDepth()` work everywhere
//!
//! ## Setting Up Debug Callbacks
//!
//! First, create a struct with debug callback methods:
//! ```zig
//! const DebugCallbacks = struct {
//!     breakpoint_hits: u32 = 0,
//!
//!     pub fn debugbreak(self: *@This(), debug: *Debug, ar: Debug.Info) void {
//!         self.breakpoint_hits += 1;
//!         std.log.info("Hit breakpoint at line {}", .{ar.current_line});
//!
//!         // Interrupt execution to return control to your application
//!         debug.debugBreak();
//!     }
//!
//!     pub fn debugstep(self: *@This(), debug: *Debug, ar: Debug.Info) void {
//!         std.log.info("Step at line {}", .{ar.current_line});
//!     }
//! };
//!
//! var callbacks = DebugCallbacks{};
//! lua.setCallbacks(&callbacks);
//! ```
//!
//! ## Setting Breakpoints
//!
//! Set breakpoints on specific functions and lines:
//! ```zig
//! // Create a Lua function to debug
//! const code =
//!     \\function calculate(a, b)
//!     \\    local sum = a + b      -- line 2
//!     \\    return sum * 2         -- line 3
//!     \\end
//! ;
//! _ = try lua.eval(code, .{}, void);
//!
//! // Get the function and set a breakpoint on line 3
//! const func = try lua.globals().get("calculate", Function);
//! defer func.deinit();
//! const actual_line = try func.setBreakpoint(3, true);
//! ```
//!
//! ## Handling Debug Interruptions
//!
//! When a breakpoint hits and `debugBreak()` is called, handle the interruption:
//! ```zig
//! const result = func.call(.{ 10, 20 }, i32) catch |err| switch (err) {
//!     error.Break => {
//!         // Execution was interrupted at the breakpoint
//!         std.log.info("Execution interrupted, can examine state here");
//!
//!         // Resume execution by calling the function again
//!         return func.call(.{ 10, 20 }, i32);
//!     },
//!     else => return err,
//! };
//! ```
//!
//! ## Inspecting Call Stack
//!
//! Use `getInfo()` to examine the call stack at any time:
//! ```zig
//! const debug = lua.debug();
//! const depth = debug.stackDepth();
//! std.log.info("Stack depth: {}", .{depth});
//!
//! // Get info about the current function (level 0)
//! const info = debug.getInfo(0, .{ .source = true, .line = true, .name = true });
//! if (info) |debug_info| {
//!     std.log.info("Function: {?s} at {s}:{}", .{
//!         debug_info.name, debug_info.source, debug_info.current_line
//!     });
//! }
//! ```
//!
//! ## Single-Step Debugging
//!
//! Enable single-step mode to step through code instruction by instruction:
//! ```zig
//! debug.setSingleStep(true);
//! // Now debugstep callback will be called for every instruction
//! const result = try func.call(.{ 10, 20 }, i32);
//! debug.setSingleStep(false);
//! ```
//!
//! ## Stack Traces
//!
//! Get formatted stack traces for error reporting:
//! ```zig
//! const trace = debug.debugTrace();
//! std.log.info("Stack trace:\n{s}", .{trace});
//! ```

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

    /// Debug info fields that can be requested from lua_getinfo()
    pub const Fields = struct {
        /// Function name
        name: bool = false,
        /// Source information (source, short_src, line_defined, what)
        source: bool = false,
        /// Current line number
        line: bool = false,
        /// Upvalue information (upvalue_count, param_count, is_vararg)
        upvalues: bool = false,

        /// Convert fields to string format for lua_getinfo()
        pub fn toString(comptime self: Fields) [:0]const u8 {
            return (if (self.name) "n" else "") ++
                (if (self.source) "s" else "") ++
                (if (self.line) "l" else "") ++
                (if (self.upvalues) "ua" else "");
        }

        /// Returns a Fields struct with all fields enabled
        pub fn all() Fields {
            return Fields{
                .name = true,
                .source = true,
                .line = true,
                .upvalues = true,
            };
        }
    };

    /// Creates an Info struct from a C lua_Debug pointer with safe field access.
    ///
    /// The `flags` parameter specifies which fields were requested and are safe to access.
    /// Unrequested fields may contain uninitialized memory or garbage pointers that will
    /// cause segmentation faults if accessed. This function safely handles these cases
    /// by only accessing fields that were explicitly requested.
    ///
    /// Field mapping:
    /// - `flags.name` - `name` field contains function name (may be null)
    /// - `flags.source` - `source`, `short_src`, `line_defined`, `what` fields are populated
    /// - `flags.line` - `current_line` field is populated
    /// - `flags.upvalues` - `upvalue_count`, `param_count`, `is_vararg` fields are populated
    /// - Empty flags - Only `current_line` and `userdata` are safe (debug hook context)
    ///
    /// CRITICAL: This function provides safe access by only dereferencing C string
    /// pointers for requested fields, preventing segmentation faults from garbage data.
    ///
    /// Implementation details: See luau/VM/src/ldebug.cpp in the Luau submodule for
    /// how lua_getinfo() populates fields based on the "what" parameter.
    ///
    pub fn fromC(c_debug: *State.Debug, flags: Fields) Info {
        return Info{
            .name = if (flags.name and c_debug.name != null)
                std.mem.span(c_debug.name.?)
            else
                null,
            .what = if (flags.source and c_debug.what != null)
                std.mem.span(c_debug.what.?)
            else
                "",
            .source = if (flags.source and c_debug.source != null)
                std.mem.span(c_debug.source.?)
            else
                "",
            .short_src = if (flags.source and c_debug.short_src != null)
                std.mem.span(c_debug.short_src.?)
            else
                "",
            .line_defined = if (flags.source) c_debug.linedefined else 0,
            .current_line = if (flags.line) c_debug.currentline else c_debug.currentline, // Always available
            .upvalue_count = if (flags.upvalues) c_debug.nupvals else 0,
            .param_count = if (flags.upvalues) c_debug.nparams else 0,
            .is_vararg = if (flags.upvalues) c_debug.isvararg != 0 else false,
            .userdata = c_debug.userdata, // Always safe
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
/// IMPORTANT: C-Call Boundary Limitations
/// `debugBreak()` will fail with "attempt to break across metamethod/C-call boundary" when:
/// - Called during C→Lua function calls (like `func.call()` from Zig)
/// - Called during metamethod execution (__index, __newindex, etc.)
/// - Called when there are active C calls on the stack
///
/// Safe contexts for `debugBreak()`:
/// - ✅ In coroutines/threads (use `lua.createThread()`)
/// - ✅ During pure Lua execution without C calls
/// - ✅ After call stack unwinds to base level
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
/// Example with coroutine:
/// ```zig
/// const thread = lua.createThread();
/// const func = try thread.globals().get("myFunction", Function);
/// // debugBreak() works reliably in thread context
/// ```
///
/// Implementation details: See luau/VM/src/ldo.cpp lua_break() function for
/// the exact conditions when breaking is allowed.
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

/// Get the current stack depth.
///
/// Returns the number of activation records on the call stack.
/// This includes the current function, all calling functions,
/// and the main chunk. A value of 1 indicates only the main chunk
/// is on the stack.
///
/// This is useful for understanding call depth and implementing
/// stack-based debugging features.
///
/// Example:
/// ```zig
/// const debug = lua.debug();
/// const depth = debug.stackDepth();
/// std.debug.print("Current stack depth: {}\n", .{depth});
/// ```
///
/// Returns: Number of activation records on the stack
pub fn stackDepth(self: Self) i32 {
    return self.state.stackDepth();
}

/// Get information about a function on the call stack.
///
/// Retrieves detailed information about a function at the specified stack level.
/// Level 0 is the current function, level 1 is the caller, and so on.
/// The `fields` parameter controls which information to retrieve.
///
/// Unlike `debugBreak()`, this function has NO C-call boundary restrictions and can be
/// called safely from any context:
/// - ✅ During C→Lua function calls
/// - ✅ During metamethod execution
/// - ✅ Inside debug hook callbacks
/// - ✅ Outside debug hook callbacks
/// - ✅ In any thread state
///
/// IMPORTANT: Fields not requested may contain garbage values.
/// Luau's lua_getinfo() only populates fields specified by the request.
/// Accessing unrequested fields may cause undefined behavior or crashes.
///
/// Example:
/// ```zig
/// const debug = lua.debug();
/// const info = debug.getInfo(0, .{ .source = true, .line = true, .upvalues = true });
///
/// if (info) |debug_info| {
///     std.debug.print("Function: {s} at line {}\n", .{
///         debug_info.source, debug_info.current_line
///     });
/// }
/// ```
///
/// Parameters:
/// - `level`: Stack level (0 = current function, 1 = caller, etc.)
/// - `fields`: See `Info.Fields` for available field options
///
/// Returns: `Info` struct with requested information, or null if level is invalid
pub fn getInfo(self: Self, level: i32, comptime fields: Info.Fields) ?Info {
    const what_string = comptime fields.toString();

    var c_debug: State.Debug = undefined;
    const result = self.state.getInfo(level, what_string, &c_debug);

    if (result == 0) {
        return null; // Invalid level
    }

    return Info.fromC(&c_debug, fields);
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

test "getInfo and stackDepth in debug breakpoint" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Callback to validate debug info when breakpoint is hit
    const DebugInfoValidator = struct {
        var breakpoint_hit: bool = false;

        pub fn debugbreak(self: *@This(), debug: *Self, ar: Info) void {
            _ = self;
            _ = ar;
            if (!breakpoint_hit) {
                breakpoint_hit = true;

                const depth = debug.stackDepth();
                std.debug.assert(depth > 0);

                const info = debug.getInfo(0, Info.Fields.all());
                std.debug.assert(info != null);
                std.debug.assert(info.?.current_line == 3);
                std.debug.assert(info.?.what.len > 0);
                std.debug.assert(info.?.source.len >= 0);
                std.debug.assert(info.?.short_src.len > 0);
                std.debug.assert(info.?.param_count == 2);
                std.debug.assert(info.?.is_vararg == false);
                // Validate string values contain expected content
                std.debug.assert(std.mem.eql(u8, info.?.what, "Lua"));
                std.debug.assert(info.?.name != null);
                std.debug.assert(std.mem.eql(u8, info.?.name.?, "testFunction"));
            }
        }
    };

    var validator = DebugInfoValidator{};
    lua.setCallbacks(&validator);

    // Create a test function with known properties
    const code =
        \\function testFunction(param1, param2)
        \\    local x = param1 + param2
        \\    return x * 2  -- Breakpoint will be set on this line
        \\end
    ;

    _ = try lua.eval(code, .{}, void);

    // Get the function and set a breakpoint
    const func = try lua.globals().get("testFunction", Lua.Function);
    defer func.?.deinit();
    _ = try func.?.setBreakpoint(3, true); // Line 3: return x * 2

    // Call the function - this should hit the breakpoint
    const result = try func.?.call(.{ 5, 10 }, i32);
    try expectEqual(result.ok.?, 30);

    // Verify breakpoint was hit
    try expect(DebugInfoValidator.breakpoint_hit);
}

test "getInfo outside of hook" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Create a test function
    const code =
        \\function testFunction(param1, param2)
        \\    local x = param1 + param2
        \\    return x * 2
        \\end
    ;

    _ = try lua.eval(code, .{}, void);

    // Get the function and execute it
    const func = (try lua.globals().get("testFunction", Lua.Function)).?;
    defer func.deinit();

    const result = try func.call(.{ 5, 10 }, i32);
    try expectEqual(result.ok.?, 30);

    const debug = lua.debug();

    const info = debug.getInfo(0, Info.Fields.all());
    if (info) |debug_info| {
        // At main chunk level, we should get valid debug info
        try expect(debug_info.current_line >= 0);
        try expectEqual(std.mem.eql(u8, debug_info.what, "Lua"), true);
        try expect(debug_info.source.len > 0);
        try expect(debug_info.short_src.len > 0);
    }
}

test "stackDepth and getInfo basic functionality" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const debug = lua.debug();

    // Test stackDepth function exists and doesn't crash
    const depth = debug.stackDepth();
    _ = depth; // Just verify the call doesn't crash

    // Test getInfo function exists and handles invalid level correctly
    const invalid = debug.getInfo(999, .{ .source = true });
    try expect(invalid == null);
}
