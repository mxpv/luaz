const std = @import("std");

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

const testing = std.testing;

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}
