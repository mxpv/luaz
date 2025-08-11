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
    pub fn fromC(c_debug: *State.Debug) Debug {
        return Debug{
            .name = if (c_debug.name) |n| std.mem.span(n) else null,
            .what = std.mem.span(c_debug.what),
            .source = std.mem.span(c_debug.source),
            .short_src = std.mem.span(c_debug.short_src),
            .line_defined = c_debug.linedefined,
            .current_line = c_debug.currentline,
            .upvalue_count = c_debug.nupvals,
            .param_count = c_debug.nparams,
            .is_vararg = c_debug.isvararg != 0,
        };
    }
};
