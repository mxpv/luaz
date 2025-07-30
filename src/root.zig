const std = @import("std");
const ArgsTuple = std.meta.ArgsTuple;

pub const State = @import("state.zig").State;
pub const Compiler = @import("compile.zig").Compiler;

pub const Error = error{
    OutOfMemory,
    Compile,
};

const Lua = struct {
    const Self = @This();

    state: State,

    pub fn init() !Self {
        return Lua{
            .state = State.init() orelse return Error.OutOfMemory,
        };
    }

    inline fn fromState(state: State.LuaState) Self {
        return Self{
            .state = State{ .lua = state },
        };
    }

    pub fn deinit(self: Lua) void {
        self.state.deinit();
    }

    /// A reference to a Lua value.
    ///
    /// Holds a reference ID that can be used to retrieve the value later.
    /// Must be explicitly released using deinit() to avoid memory leaks.
    pub const Ref = struct {
        lua: State,
        ref: c_int,

        /// Releases the Lua reference, allowing the referenced value to be garbage collected.
        pub fn deinit(self: Ref) void {
            self.lua.unref(self.ref);
        }

        /// Checks if the reference is valid (not nil or invalid).
        pub inline fn isValid(self: Ref) bool {
            return self.ref != State.REFNIL and self.ref != State.NOREF;
        }

        /// Checks if the referenced value is a function.
        pub inline fn isFunction(self: Ref) bool {
            return self.lua.isFunction(self.ref);
        }

        /// Checks if the referenced value is a table.
        pub inline fn isTable(self: Ref) bool {
            return self.lua.isTable(self.ref);
        }
    };

    /// Creates a reference to a value on the stack.
    ///
    /// Does not consume the value.
    fn createRef(self: Self, index: i32) Ref {
        const ref = self.state.ref(index);

        return Ref{
            .lua = self.state,
            .ref = ref,
        };
    }

    /// Sets a global variable in the Lua environment.
    ///
    /// Pushes the value onto the stack and assigns it to the specified global variable name.
    /// The value is automatically converted using the same rules as the `push` function.
    ///
    /// Examples:
    /// ```zig
    /// lua.setGlobal("x", 42);           // Set global x = 42
    /// lua.setGlobal("name", "hello");   // Set global name = "hello"
    /// lua.setGlobal("flag", true);      // Set global flag = true
    /// lua.setGlobal("func", myFunction);// Set global func to a Zig function
    /// ```
    pub fn setGlobal(self: Self, key: [:0]const u8, value: anytype) void {
        self.push(value);
        self.state.setField(State.GLOBALSINDEX, key);
    }

    /// Gets a global variable from the Lua environment and converts it to the specified Zig type.
    ///
    /// Retrieves the global variable and attempts to convert it to type `T` using the same
    /// conversion rules as the `pop` function. Supports the same type conversions as `pop`:
    /// - Lua boolean → `bool`
    /// - Lua number/integer → Integer types (`i8`, `i32`, `i64`, etc.)
    /// - Lua number → Float types (`f32`, `f64`)
    /// - Lua nil → Optional types (`?T`) as `null`
    /// - Any valid value → Optional types (`?T`) as wrapped value
    ///
    /// Returns `null` if the global doesn't exist or cannot be converted to the requested type.
    ///
    /// Examples:
    /// ```zig
    /// const x = lua.getGlobal("x", i32);        // Get global x as i32
    /// const name = lua.getGlobal("name", []u8); // Get global name as string
    /// const flag = lua.getGlobal("flag", bool); // Get global flag as bool
    /// ```
    ///
    /// Returns: `?T` - The converted value, or `null` if not found or conversion failed
    pub fn getGlobal(self: Self, key: [:0]const u8, comptime T: type) ?T {
        _ = self.state.getField(State.GLOBALSINDEX, key);
        return self.pop(T);
    }

    /// Pushes a Zig value onto the Lua stack.
    ///
    /// Automatically converts Zig types to their Lua equivalents:
    /// - `bool` → Lua boolean
    /// - Integer types (`i8`, `i32`, `i64`, etc.) → Lua integer
    /// - Float types (`f32`, `f64`) → Lua number
    /// - `null` → Lua nil
    /// - `void` → Pushes nothing
    /// - Optional types (`?T`) → Recursively pushes the wrapped value or nil
    /// - Tuple types → Each field pushed individually onto the stack
    /// - Function types → Wrapped as Lua C function with automatic argument conversion
    ///
    /// For function types, creates a trampoline that automatically converts Lua arguments
    /// to Zig types using the `check` function and converts the return value back to Lua.
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
    ///
    /// // Function example
    /// fn add(a: i32, b: i32) i32 { return a + b; }
    /// lua.push(add);          // Becomes callable Lua function
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
            .void => {
                // Push nothing.
            },
            .null => {
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

                // Handle Ref type
                if (T == Ref) {
                    if (value.isValid()) {
                        _ = self.state.rawGetI(State.REGISTRYINDEX, value.ref);
                    } else {
                        self.state.pushNil();
                    }

                    break :blk;
                }

                @compileError("Non tuple structs are not yet implemented");
            },
            .@"fn" => {
                if (*const T == @typeInfo(State.CFunction).optional.child) {
                    self.state.pushCFunction(value, @typeName(T));
                    break :blk;
                }

                const trampoline: State.CFunction = struct {
                    fn f(state: ?State.LuaState) callconv(.C) c_int {
                        const lua = Lua.fromState(state.?);

                        // Push func arguments
                        // See https://www.lua.org/pil/26.1.html
                        var args: ArgsTuple(T) = undefined;
                        inline for (std.meta.fields(ArgsTuple(T)), 0..) |field, i| {
                            args[i] = lua.check(i + 1, field.type);
                        }

                        // Call Zig func
                        const result = @call(.auto, value, args);

                        // Push function results onto Lua stack.
                        const current = lua.top();
                        lua.push(result);

                        return lua.top() - current;
                    }
                }.f;

                self.state.pushCFunction(trampoline, @typeName(T));
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
        if (T == void) {
            return;
        }

        defer self.state.pop(1);
        return self.toValue(T, -1);
    }

    pub inline fn top(self: Self) i32 {
        return self.state.getTop();
    }

    /// Internal function to check and convert a value at the specified stack index to the given Zig type.
    /// Used by the trampoline function to validate function arguments.
    fn check(self: Self, index: i32, comptime T: type) T {
        const type_info = @typeInfo(T);
        switch (type_info) {
            .bool => {
                return self.state.checkBoolean(index);
            },
            .int, .comptime_int => {
                const lua_int = self.state.checkInteger(index);
                return @intCast(lua_int);
            },
            .float, .comptime_float => {
                const lua_num = self.state.checkNumber(index);
                return @floatCast(lua_num);
            },
            .optional => {
                return if (self.state.isNil(index))
                    null
                else
                    self.check(index, type_info.optional.child);
            },
            else => {
                @compileError("Unable to check type " ++ @typeName(T));
            },
        }
    }

    /// Internal function to convert a value at the specified stack index to the given Zig type.
    /// Used internally by the pop() function.
    fn toValue(self: Self, comptime T: type, index: i32) ?T {
        const type_info = @typeInfo(T);
        switch (type_info) {
            .bool => {
                return if (self.state.isBoolean(index))
                    self.state.toBoolean(index)
                else
                    null;
            },
            .int, .comptime_int => {
                return if (self.state.toIntegerX(index)) |integer|
                    @intCast(integer)
                else
                    null;
            },
            .float, .comptime_float => {
                return if (self.state.toNumberX(index)) |number|
                    @floatCast(number)
                else
                    null;
            },
            .optional => {
                return if (self.state.isNil(index))
                    null
                else
                    self.toValue(type_info.optional.child, index);
            },
            else => {
                @compileError("Unable to cast type " ++ @typeName(T));
            },
        }
    }

    /// Executes pre-compiled Luau bytecode and returns the result.
    ///
    /// Loads the provided bytecode onto the Lua stack and executes it as a function.
    /// The bytecode should be valid Luau bytecode (not LuaJit).
    ///
    /// The return type `T` specifies what type to expect from the executed code:
    /// - `void` - Executes code that returns nothing
    /// - `i32`, `f64`, `bool`, etc. - Converts the return value to the specified type
    /// - `?T` - Optional types, returns `null` if conversion fails
    ///
    /// Examples:
    /// ```zig
    /// // Execute bytecode that returns a number
    /// const result = try lua.exec(bytecode, i32);
    ///
    /// // Execute bytecode that returns nothing
    /// try lua.exec(bytecode, void);
    ///
    /// // Execute bytecode with optional return type
    /// const maybe_result = try lua.exec(bytecode, ?f64);
    /// ```
    ///
    /// Returns: The result of executing the bytecode, converted to type `T`
    /// Errors: `Error.OutOfMemory` if the VM runs out of memory during execution
    pub fn exec(self: Self, blob: []const u8, comptime T: type) !T {
        // Push byte code onto stack
        {
            const status = self.state.load("", blob, 0);

            // Load can either succeed or get an OOM error
            // See https://github.com/luau-lang/luau/blob/66202dc4ac15f39a6ce8f732e2be19b636ee2af1/VM/src/lvmload.cpp#L643
            switch (status) {
                .ok => {},
                .errmem => return Error.OutOfMemory,
                else => unreachable,
            }

            std.debug.assert(self.state.isFunction(-1));
        }

        // Execute Lua func
        {
            const nret = if (T == void) 0 else 1;

            self.state.call(0, nret);

            return self.pop(T).?;
        }
    }

    /// Compiles and executes Luau source code, returning the result.
    ///
    /// Takes Luau source code as a string, compiles it to bytecode using the provided
    /// compilation options, and then executes the resulting bytecode. This is a
    /// convenience function that combines compilation and execution in one step.
    ///
    /// The return type `T` specifies what type to expect from the executed code:
    /// - `void` - Executes code that returns nothing
    /// - `i32`, `f64`, `bool`, etc. - Converts the return value to the specified type
    /// - `?T` - Optional types, returns `null` if conversion fails
    ///
    /// Examples:
    /// ```zig
    /// // Execute simple arithmetic
    /// const result = try lua.eval("return 2 + 3", .{}, i32); // Returns 5
    ///
    /// // Execute code with no return value
    /// try lua.eval("print('Hello, World!')", .{}, void);
    ///
    /// // Execute with compilation options
    /// const result = try lua.eval("return math.sqrt(16)", .{ .optLevel = 2 }, f64);
    ///
    /// // Execute with optional return type
    /// const maybe_result = try lua.eval("return getValue()", .{}, ?i32);
    /// ```
    ///
    /// Parameters:
    /// - `source`: Luau source code to compile and execute
    /// - `opts`: Compilation options (see `Compiler.Opts` for available options)
    /// - `T`: Expected return type
    ///
    /// Returns: The result of executing the compiled code, converted to type `T`
    /// Errors:
    /// - `Error.Compile` if the source code contains syntax errors
    /// - `Error.OutOfMemory` if compilation or execution runs out of memory
    pub fn eval(self: Self, source: []const u8, opts: Compiler.Opts, comptime T: type) !T {
        const result = try Compiler.compile(source, opts);
        defer result.deinit();

        if (result == .err) {
            return Error.Compile;
        }

        const blob = result.ok;
        return self.exec(blob, T);
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

// Test functions for function push test
fn testCFunction(state: ?State.LuaState) callconv(.C) c_int {
    _ = state;
    return 0;
}

fn testAdd(a: i32, b: i32) i32 {
    return a + b;
}

test "Push C and Zig functions" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test C function
    lua.push(testCFunction);
    try expect(lua.state.isFunction(-1));
    try expect(lua.state.isCFunction(-1));
    lua.state.pop(1);
    try expectEq(lua.top(), 0);

    // Test Zig function
    lua.push(testAdd);
    try expect(lua.state.isFunction(-1));
    try expect(lua.state.isCFunction(-1)); // Zig functions are wrapped as C functions
    lua.state.pop(1);
    try expectEq(lua.top(), 0);
}

test "call zig func" {
    const lua = try Lua.init();
    defer lua.deinit();

    lua.setGlobal("add", testAdd);
    const sum = try lua.eval("return add(10, 20)", .{}, u32);
    try expectEq(sum, 30);
}

test "Ref types" {
    const lua = try Lua.init();
    defer lua.deinit();

    lua.push(testAdd);
    try expectEq(lua.top(), 1); // C function

    const ref = lua.createRef(-1);
    defer ref.deinit();

    try expectEq(lua.top(), 1); // Ref should not consume the value

    try expect(ref.isValid());
    try expect(ref.isFunction());
    try expect(!ref.isTable());

    lua.state.pop(1);
    try expectEq(lua.top(), 0);
}

test "Push Ref to stack" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Push original function and create ref
    lua.push(testAdd);
    const ref = lua.createRef(-1);
    defer ref.deinit();

    // Clear the stack
    lua.state.pop(1);
    try expectEq(lua.top(), 0);

    // Push the ref back to stack
    lua.push(ref);
    try expectEq(lua.top(), 1);

    try expect(lua.state.isFunction(-1));
}

test "Global variables" {
    const lua = try Lua.init();
    defer lua.deinit();

    lua.setGlobal("x", @as(i32, 42));
    try expectEq(lua.getGlobal("x", i32).?, 42);

    lua.setGlobal("flag", true);
    try expect(lua.getGlobal("flag", bool).? == true);

    lua.setGlobal("pi", @as(f32, 3.14));
    try expectEq(lua.getGlobal("pi", f32).?, 3.14);

    lua.setGlobal("maybe", @as(?i32, 123));
    try expectEq(lua.getGlobal("maybe", ?i32).?, 123);

    try expectEq(lua.getGlobal("nonexistent", i32), null);

    try expectEq(lua.top(), 0);
}

test "eval function" {
    const lua = try Lua.init();
    defer lua.deinit();

    const result = try lua.eval("return 2 + 3", .{}, i32);
    try expectEq(result, 5);

    try lua.eval("x = 42", .{}, void);
    try expectEq(lua.getGlobal("x", i32).?, 42);

    const flag = try lua.eval("return true", .{}, bool);
    try expect(flag == true);

    // Test with compilation options
    const optimized = try lua.eval("return 10 * 5", .{ .optLevel = 2 }, i32);
    try expectEq(optimized, 50);

    try expectEq(lua.top(), 0);
}

test "eval compilation error" {
    const lua = try Lua.init();
    defer lua.deinit();

    const compile_error = lua.eval("return 1 + '", .{}, i32);
    try expect(compile_error == Error.Compile);

    try expectEq(lua.top(), 0);
}
