const std = @import("std");

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
});

/// Lua state wrapper providing safe access to Lua VM operations
const State = struct {
    lua: *c.lua_State,

    /// Initialize a new Lua state
    pub fn init() State {
        return State{
            .lua = c.luaL_newstate() orelse unreachable,
        };
    }

    /// Clean up and close the Lua state
    pub fn deinit(self: State) void {
        c.lua_close(self.lua);
    }

    /// Get the current Lua VM clock time
    pub fn clock(self: State) f64 {
        return c.lua_clock(self.lua);
    }
};

const expect = std.testing.expect;

test "Read clock" {
    const state = State.init();
    defer state.deinit();

    const clock = state.clock();
    try expect(clock > 0.0);
}
