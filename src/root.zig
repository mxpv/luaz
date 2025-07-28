const std = @import("std");
const state = @import("state.zig");
const clock = state.clock;

test {
    std.testing.refAllDeclsRecursive(@This());
}
