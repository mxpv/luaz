const std = @import("std");
const State = @import("state.zig").State;

const Error = error{
    OutOfMemory,
};

const Lua = struct {
    const Self = @This();

    state: State,

    pub fn init() !Lua {
        return Lua{
            .state = State.init() orelse return Error.OutOfMemory,
        };
    }

    pub fn deinit(self: Lua) void {
        self.state.deinit();
    }

    /// Pushes a Zig value onto the Lua stack.
    ///
    /// Automatically converts Zig types to their Lua equivalents:
    /// - `bool` → Lua boolean
    /// - Integer types (`i8`, `i32`, `i64`, etc.) → Lua integer or number
    /// - Float types (`f32`, `f64`) → Lua number
    /// - `null` or `void` → Lua nil
    /// - Optional types (`?T`) → Recursively pushes the wrapped value or nil
    /// - Tuple types → Each field pushed individually onto the stack
    ///
    /// For integer types larger than `c_int`, values are automatically stored as
    /// Lua numbers to prevent overflow.
    ///
    /// Examples:
    /// ```zig
    /// lua.push(42);           // Integer
    /// lua.push(3.14);         // Float
    /// lua.push(true);         // Boolean
    /// lua.push(@as(?i32, 5)); // Optional with value
    /// lua.push(@as(?i32, null)); // Optional null → nil
    /// lua.push(.{1, 2, 3});   // Tuple → pushes 1, 2, 3 individually
    /// lua.push(.{});          // Empty tuple → pushes nothing
    /// ```
    pub fn push(self: Self, value: anytype) void {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        blk: switch (type_info) {
            .bool => {
                self.state.pushBoolean(value);
            },
            .int, .comptime_int => {
                self.state.pushInteger(@intCast(value));
            },
            .float, .comptime_float => {
                self.state.pushNumber(value);
            },
            .null, .void => {
                self.state.pushNil();
            },
            .optional => {
                if (value == null) {
                    self.state.pushNil();
                } else {
                    self.push(value.?);
                }
            },
            .@"struct" => |info| {
                // Tuples are treated as a sequence of values.
                // See https://ziglang.org/documentation/master/#toc-Tuples
                if (info.is_tuple) {
                    inline for (info.fields, 0..) |_, i| {
                        self.push(value[i]);
                    }

                    break :blk;
                }

                @compileError("Non tuple structs are not yet implemented");
            },
            else => {
                @compileError("Unable to push type " ++ @typeName(T));
            },
        }
    }

    /// Pops a value from the top of the Lua stack and converts it to the specified Zig type.
    ///
    /// Returns `null` if the value at the top of the stack cannot be converted to type `T`.
    /// The value is automatically removed from the stack regardless of conversion success.
    ///
    /// Supported type conversions:
    /// - Lua boolean → `bool`
    /// - Lua number/integer → Integer types (`i8`, `i32`, `i64`, etc.)
    /// - Lua number → Float types (`f32`, `f64`)
    /// - Lua nil → Optional types (`?T`) as `null`
    /// - Any valid value → Optional types (`?T`) as wrapped value
    ///
    /// Examples:
    /// ```zig
    /// lua.push(42);
    /// const value = lua.pop(i32).?; // 42
    ///
    /// lua.push(null);
    /// const optional = lua.pop(?i32); // null
    /// ```
    ///
    /// Returns: `?T` - The converted value, or `null` if conversion failed
    pub inline fn pop(self: Self, comptime T: type) ?T {
        defer self.state.pop(1);
        return self.toValue(T, -1);
    }

    pub inline fn top(self: Self) i32 {
        return self.state.getTop();
    }

    /// Converts a value at the specified stack index to the given Zig type.
    ///
    /// Unlike `pop()`, this function does not modify the stack - it only reads and converts
    /// the value at the specified index.
    ///
    /// Stack indexing:
    /// - Positive indices (1, 2, 3, ...) count from the bottom of the stack
    /// - Negative indices (-1, -2, -3, ...) count from the top of the stack
    /// - `-1` refers to the top element, `-2` to the second from top, etc.
    ///
    /// Type conversion rules:
    /// - Lua boolean → `bool` (returns `null` if not a boolean)
    /// - Lua number/integer → Integer types with appropriate casting
    /// - Lua number → Float types with appropriate casting
    /// - Lua nil → Optional types (`?T`) as `null`
    /// - Valid values → Optional types (`?T`) as wrapped values
    ///
    /// Examples:
    /// ```zig
    /// lua.push(42);
    /// lua.push(3.14);
    ///
    /// const int_val = lua.toValue(i32, -2).?; // 42 (second from top)
    /// const float_val = lua.toValue(f32, -1).?; // 3.14 (top)
    ///
    /// // Check for nil
    /// const maybe_val = lua.toValue(?i32, -1); // null if nil, value if not
    /// ```
    ///
    /// Arguments:
    /// - `T`: The target Zig type for conversion
    /// - `index`: Stack index of the value to convert
    ///
    /// Returns: `?T` - The converted value, or `null` if conversion failed
    pub fn toValue(self: Self, comptime T: type, index: i32) ?T {
        const type_info = @typeInfo(T);
        switch (type_info) {
            .bool => {
                return if (self.state.isBoolean(index))
                    self.state.toBoolean(index)
                else
                    null;
            },
            .int, .comptime_int => {
                if (self.state.toIntegerX(index)) |integer| {
                    return @intCast(integer);
                } else {
                    return null;
                }
            },
            .float, .comptime_float => {
                if (self.state.toNumberX(index)) |number| {
                    return @floatCast(number);
                } else {
                    return null;
                }
            },
            .optional => {
                if (self.state.isNil(index)) {
                    return null;
                } else {
                    return self.toValue(type_info.optional.child, index);
                }
            },
            else => {
                @compileError("Unable to cast type " ++ @typeName(T));
            },
        }
    }
};

const expect = std.testing.expect;
const expectEq = std.testing.expectEqual;

test "Push and pop different integer sizes" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test different integer sizes
    lua.push(@as(i8, 127));
    try expect(lua.pop(i8).? == 127);

    lua.push(@as(i16, 32767));
    try expect(lua.pop(i16).? == 32767);

    lua.push(@as(i32, 2147483647));
    try expect(lua.pop(i32).? == 2147483647);

    lua.push(@as(u8, 255));
    try expect(lua.pop(u8).? == 255);

    try expectEq(lua.top(), 0);
}

test "Push and pop different float sizes" {
    const lua = try Lua.init();
    defer lua.deinit();

    lua.push(@as(f32, 3.14159));
    try expectEq(lua.pop(f32).?, 3.14159);

    lua.push(@as(f64, 2.718281828459045));
    try expectEq(lua.pop(f64).?, 2.718281828459045);

    // Test that we can convert between float types
    lua.push(@as(f64, 1.5));
    try expectEq(lua.pop(f32).?, 1.5);

    try expectEq(lua.top(), 0);
}

test "Push and pop optional types" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test optional with value
    lua.push(@as(?i32, 42));
    try expect(lua.pop(?i32).? == 42);

    lua.push(@as(?i32, 42));
    try expect(lua.pop(i32).? == 42);

    // Test optional null
    lua.push(@as(?i32, null));
    try expect(lua.pop(?i32) == null);

    // Test optional bool
    lua.push(@as(?bool, true));
    try expect(lua.pop(?bool).? == true);

    lua.push(@as(?bool, null));
    try expect(lua.pop(?bool) == null);

    // Test optional float
    lua.push(@as(?f32, 3.14));
    try expectEq(lua.pop(?f32).?, 3.14);

    lua.push(@as(?f32, null));
    try expect(lua.pop(?f32) == null);

    try expectEq(lua.top(), 0);
}

test "Push and pop edge cases" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test zero values
    lua.push(@as(i32, 0));
    try expect(lua.pop(i32).? == 0);

    lua.push(@as(f32, 0.0));
    try expectEq(lua.pop(f32).?, 0.0);

    lua.push(false);
    try expect(lua.pop(bool).? == false);

    // Test negative values
    lua.push(@as(i32, -42));
    try expect(lua.pop(i32).? == -42);

    lua.push(@as(f32, -3.14));
    try expectEq(lua.pop(f32).?, -3.14);

    // Test comptime values
    lua.push(123);
    try expect(lua.pop(i32).? == 123);

    lua.push(4.56);
    try expectEq(lua.pop(f32).?, 4.56);

    try expectEq(lua.top(), 0);
}

test "Push and pop tuples" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test empty tuple
    lua.push(.{});
    try expectEq(lua.top(), 0); // Empty tuple pushes nothing

    // Test single element tuple
    lua.push(.{42});
    try expect(lua.pop(i32).? == 42);
    try expectEq(lua.top(), 0);

    // Test two element tuple
    lua.push(.{ 123, 3.14 });
    try expectEq(lua.pop(f32).?, 3.14); // Second element (top of stack)
    try expect(lua.pop(i32).? == 123); // First element
    try expectEq(lua.top(), 0);

    // Test mixed type tuple
    lua.push(.{ true, @as(?i32, null), 456, 2.718 });
    try expectEq(lua.pop(f64).?, 2.718); // Fourth element
    try expect(lua.pop(i32).? == 456); // Third element
    try expect(lua.pop(?i32) == null); // Second element (null)
    try expect(lua.pop(bool).? == true); // First element
    try expectEq(lua.top(), 0);

    // Test nested tuple (tuple elements are pushed individually)
    lua.push(.{ .{ 1, 2 }, 3 });
    try expect(lua.pop(i32).? == 3); // Third element
    try expect(lua.pop(i32).? == 2); // Second element of nested tuple
    try expect(lua.pop(i32).? == 1); // First element of nested tuple
    try expectEq(lua.top(), 0);
}
