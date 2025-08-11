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
//!     pub fn debugbreak(self: *@This(), lua: *Lua, ar: Debug) void {
//!         std.log.info("Hit breakpoint at line {}", .{ar.current_line});
//!         // Call debugBreak() to actually interrupt execution
//!         lua.debugBreak();
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
//! 2. In callback → Call `lua.debugBreak()` to interrupt execution
//! 3. VM interrupts → Sets internal status to LUA_BREAK
//! 4. Function returns → `error.Break` to your application code
//! 5. Resume execution → Call the function again to continue from where it left off
//!
//! ## Key Concepts
//!
//! - Breakpoints are notifications: Setting breakpoints with `function.setBreakpoint()` only triggers
//!   the callback - it doesn't automatically stop execution.
//! - debugBreak() stops execution: You must call `lua.debugBreak()` within your
//!   callback to actually interrupt and return control to your application.
//! - Resumption: After `error.Break`, call the same function again to resume execution.
//! - Debug info limitations: Only `current_line` and `userdata` fields are populated
//!   in debug callbacks. Other fields contain garbage values.
//!
//! ## Advanced Features
//!
//! - Single stepping: Use `lua.setSingleStep(true)` and the `debugstep` callback
//! - Thread interruption: Use `debuginterrupt` callback for coroutine debugging
//! - Function breakpoints: Use `function.setBreakpoint(line)` to set breakpoints on specific functions
//! - Conditional breakpoints: Only call `debugBreak()` when certain conditions are met
//!
//! ## Debug Information
//!
//! The `Debug` struct contains information about the current execution context,
//! but note that most fields are only populated during `lua_getinfo()` calls,
//! not during debug hook callbacks.

const std = @import("std");
const State = @import("State.zig");

/// Debug information for a function activation record
pub const Debug = struct {
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

    /// Creates a Debug struct from a C lua_Debug pointer
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
    pub fn fromC(c_debug: *State.Debug) Debug {
        return Debug{
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
    pub fn getInterruptedThread(self: Debug) ?State {
        if (self.userdata) |data| {
            const lua_state: State.LuaState = @ptrCast(@alignCast(data));
            return State{ .lua = lua_state };
        }
        return null;
    }
};
