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
            .name = if (c_debug.name) |n| std.mem.span(n) else null,
            .what = if (c_debug.what) |w| std.mem.span(w) else "unknown",
            .source = if (c_debug.source) |s| std.mem.span(s) else "unknown",
            .short_src = if (c_debug.short_src) |s| std.mem.span(s) else "unknown",
            .line_defined = c_debug.linedefined,
            .current_line = c_debug.currentline,
            .upvalue_count = c_debug.nupvals,
            .param_count = c_debug.nparams,
            .is_vararg = c_debug.isvararg != 0,
        };
    }
};
