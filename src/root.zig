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
        lua: Lua,
        ref: c_int,

        /// Releases the Lua reference, allowing the referenced value to be garbage collected.
        pub fn deinit(self: Ref) void {
            self.lua.state.unref(self.ref);
        }

        /// Checks if the reference is valid (not nil or invalid).
        pub inline fn isValid(self: Ref) bool {
            return self.ref != State.REFNIL and self.ref != State.NOREF;
        }

        /// Checks if the referenced value is a function.
        pub inline fn isFunction(self: Ref) bool {
            return self.lua.state.isFunction(self.ref);
        }

        /// Checks if the referenced value is a table.
        pub inline fn isTable(self: Ref) bool {
            return self.lua.state.isTable(self.ref);
        }

        /// Returns the registry reference ID if valid, otherwise null.
        inline fn getRef(self: Ref) ?c_int {
            return if (self.isValid()) self.ref else null;
        }
    };

    /// Creates a reference to a value on the stack.
    ///
    /// Does not consume the value.
    inline fn createRef(self: Self, index: i32) Ref {
        return Ref{
            .lua = self,
            .ref = self.state.ref(index),
        };
    }

    /// High-level table wrapper providing safe access to Lua tables.
    ///
    /// Holds a reference to a Lua table and provides methods for getting and setting
    /// table values with automatic type conversion. Must be explicitly released
    /// using deinit() to avoid memory leaks.
    pub const Table = struct {
        ref: Ref,

        /// Releases the table reference, allowing the table to be garbage collected.
        pub fn deinit(self: Table) void {
            self.ref.deinit();
        }

        /// Sets a table element by integer index using raw access (bypasses `__newindex` metamethod).
        ///
        /// Directly assigns `table[index] = value` without invoking metamethods.
        /// This is faster than `set()` but doesn't respect custom table behavior.
        ///
        /// Examples:
        /// ```zig
        /// try table.setRaw(1, 42);        // table[1] = 42
        /// try table.setRaw(5, "hello");   // table[5] = "hello"
        /// try table.setRaw(-1, true);     // table[-1] = true
        /// ```
        ///
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn setRaw(self: Table, index: i32, value: anytype) !void {
            try self.ref.lua.checkStack(2);

            self.ref.lua.push(self.ref); // Push table ref
            self.ref.lua.push(value); // Push value
            self.ref.lua.state.rawSetI(-2, index); // Set table and pop value
            self.ref.lua.state.pop(1); // Pop table
        }

        /// Gets a table element by integer index using raw access (bypasses __index metamethod).
        ///
        /// Directly retrieves `table[index]` without invoking metamethods.
        /// This is faster than `get()` but doesn't respect custom table behavior.
        ///
        /// Returns `null` if the index doesn't exist or the value cannot be converted to type `T`.
        ///
        /// Examples:
        /// ```zig
        /// const value = try table.getRaw(1, i32);     // Get table[1] as i32
        /// const text = try table.getRaw(5, []u8);     // Get table[5] as string
        /// const flag = try table.getRaw(-1, bool);    // Get table[-1] as bool
        /// ```
        ///
        /// Returns: `?T` - The converted value, or `null` if not found or conversion failed
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn getRaw(self: Table, index: i32, comptime T: type) !?T {
            try self.ref.lua.checkStack(2);

            self.ref.lua.push(self.ref); // Push table ref
            _ = self.ref.lua.state.rawGetI(-1, index); // Push value of t[i] onto stack.

            defer self.ref.lua.state.pop(1); // Pop table

            return self.ref.lua.pop(T);
        }

        /// Sets a table element by key with full Lua semantics (invokes __newindex metamethod).
        ///
        /// Assigns `table[key] = value` following Lua's complete access protocol.
        /// If the table has a `__newindex` metamethod, it will be called.
        /// Use this for general table manipulation where metamethods should be honored.
        ///
        /// The key can be any type supported by the `push()` function:
        /// - Integers, floats, booleans
        /// - Strings (`[]const u8`, `[:0]const u8`, etc.)
        /// - Other Lua-compatible types
        ///
        /// Examples:
        /// ```zig
        /// try table.set("name", "Alice");     // table["name"] = "Alice"
        /// try table.set(42, "answer");        // table[42] = "answer"
        /// try table.set(true, 100);           // table[true] = 100
        /// ```
        ///
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn set(self: Table, key: anytype, value: anytype) !void {
            try self.ref.lua.checkStack(3);

            self.ref.lua.push(self.ref); // Push table ref
            self.ref.lua.push(key); // Push key
            self.ref.lua.push(value); // Push value

            self.ref.lua.state.setTable(-3); // Set table[key] = value and pop key and value
            self.ref.lua.state.pop(1); // Pop table
        }

        /// Gets a table element by key with full Lua semantics (invokes __index metamethod).
        ///
        /// Retrieves `table[key]` following Lua's complete access protocol.
        /// If the table has an `__index` metamethod, it will be called.
        /// Use this for general table access where metamethods should be honored.
        ///
        /// Returns `null` if the key doesn't exist or the value cannot be converted to type `T`.
        ///
        /// The key can be any type supported by the `push()` function.
        ///
        /// Examples:
        /// ```zig
        /// const name = try table.get("name", []u8);   // Get table["name"] as string
        /// const answer = try table.get(42, i32);      // Get table[42] as i32
        /// const flag = try table.get(true, bool);     // Get table[true] as bool
        /// ```
        ///
        /// Returns: `?T` - The converted value, or `null` if not found or conversion failed
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn get(self: Table, key: anytype, comptime T: type) !?T {
            try self.ref.lua.checkStack(2);

            self.ref.lua.push(self.ref); // Push table ref
            self.ref.lua.push(key); // Push key

            _ = self.ref.lua.state.getTable(-2); // Pop key and push "table[key]" onto stack
            defer self.ref.lua.state.pop(1); // Pop table

            return self.ref.lua.pop(T);
        }

        /// Returns the registry reference ID if valid, otherwise null.
        inline fn getRef(self: Table) ?c_int {
            return self.ref.getRef();
        }
    };

    /// Creates a new Lua table and returns a high-level Table wrapper.
    ///
    /// Creates an empty table with optional size hints for optimization.
    /// The hints help Lua preallocate memory for better performance:
    /// - `arr`: Expected number of array elements (sequential integer keys starting from 1)
    /// - `rec`: Expected number of hash table elements (non-sequential keys)
    ///
    /// The returned Table must be explicitly released using `deinit()` to avoid memory leaks.
    ///
    /// Examples:
    /// ```zig
    /// // Create empty table with no size hints
    /// const table = lua.createTable(0, 0);
    /// defer table.deinit();
    ///
    /// // Create table expecting 10 array elements
    /// const array_table = lua.createTable(10, 0);
    /// defer array_table.deinit();
    ///
    /// // Create table expecting 5 hash elements
    /// const hash_table = lua.createTable(0, 5);
    /// defer hash_table.deinit();
    ///
    /// // Create table expecting both array and hash elements
    /// const mixed_table = lua.createTable(10, 5);
    /// defer mixed_table.deinit();
    /// ```
    ///
    /// Returns: `Table` - A wrapper around the newly created Lua table
    pub inline fn createTable(self: Self, arr: u32, rec: u32) Table {
        self.state.createTable(arr, rec);
        defer self.state.pop(1);
        return Table{ .ref = self.createRef(-1) };
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
    /// - String types (`[]const u8`, `[:0]const u8`, `[*:0]const u8`, `[N:0]u8`) → Lua string
    /// - `null` → Lua nil
    /// - `void` → Pushes nothing
    /// - Optional types (`?T`) → Recursively pushes the wrapped value or nil
    /// - Tuple types → Each field pushed individually onto the stack
    /// - Function types → Wrapped as Lua C function with automatic argument conversion
    /// - `Ref` types → Pushes the referenced Lua value onto the stack
    /// - `Table` types → Pushes the table onto the stack
    ///
    /// For function types, creates a trampoline that automatically converts Lua arguments
    /// to Zig types using the `check` function and converts the return value back to Lua.
    ///
    /// Examples:
    /// ```zig
    /// lua.push(42);           // Integer
    /// lua.push(3.14);         // Float
    /// lua.push(true);         // Boolean
    /// lua.push("hello");      // String literal - safe to push
    /// lua.push(@as(?i32, 5)); // Optional with value
    /// lua.push(@as(?i32, null)); // Optional null → nil
    /// lua.push(.{1, 2, 3});   // Tuple → pushes 1, 2, 3 individually
    /// lua.push(.{});          // Empty tuple → pushes nothing
    ///
    /// // For safe string retrieval, use the specialized functions:
    /// lua.push("world");
    /// const owned = lua.popString(allocator); // Safe: returns owned copy
    /// defer allocator.free(owned.?);
    /// ```
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

                // Handle Ref and Table types
                if (T == Ref or T == Table) {
                    if (value.getRef()) |index| {
                        _ = self.state.rawGetI(State.REGISTRYINDEX, index);
                    } else {
                        self.state.pushNil();
                    }

                    break :blk;
                }

                @compileError("Non tuple structs are not yet implemented");
            },
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .one => {
                        // Handle string literal pointers: *const [N:0]u8
                        const child_type_info = @typeInfo(ptr_info.child);
                        if (child_type_info == .array and child_type_info.array.child == u8) {
                            // This is a pointer to a u8 array (string literal)
                            // Check if the array is zero-terminated
                            if (comptime std.mem.indexOf(u8, @typeName(ptr_info.child), ":0") != null) {
                                // Zero-terminated array: *const [N:0]u8
                                self.state.pushString(@as([:0]const u8, @ptrCast(value)));
                            } else {
                                // Regular array: *const [N]u8
                                self.state.pushLString(std.mem.asBytes(value));
                            }
                            break :blk;
                        }
                        @compileError("Unable to push type " ++ @typeName(T));
                    },
                    .many, .slice => {
                        // Handle strings: []const u8, [:0]const u8, [*:0]const u8
                        if (ptr_info.child == u8) {
                            // For slices, check if it's zero-terminated by examining the type
                            if (comptime std.mem.indexOf(u8, @typeName(T), ":0") != null) {
                                // Zero-terminated string: [:0]const u8, [*:0]const u8
                                self.state.pushString(@as([:0]const u8, @ptrCast(value)));
                            } else {
                                // Regular slice: []const u8
                                self.state.pushLString(value);
                            }
                            break :blk;
                        }

                        @compileError("Unable to push type " ++ @typeName(T));
                    },
                    .c => {
                        @compileError("Unable to push type " ++ @typeName(T));
                    },
                }
            },
            .array => |array_info| {
                // Handle string arrays: [N:0]u8, [N]u8, etc.
                if (array_info.child == u8) {
                    // Check if it's zero-terminated by examining the type name
                    if (comptime std.mem.indexOf(u8, @typeName(T), ":0") != null) {
                        // Zero-terminated array: [N:0]u8
                        self.state.pushString(@as([:0]const u8, @ptrCast(&value)));
                    } else {
                        // Regular array: [N]u8
                        self.state.pushLString(&value);
                    }
                    break :blk;
                }

                @compileError("Unable to push type " ++ @typeName(T));
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
    /// Note: String conversion is not supported via the generic `pop` due to Lua's garbage collection.
    /// The Lua C API returns a direct pointer to the string data inside Lua's memory. Once the value
    /// is popped from the stack, this pointer may become invalid as the string can be garbage collected.
    /// For safe string handling, use `popString(allocator)` instead, which returns an owned copy
    /// (and hence requires allocation).
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

    /// Ensures the Lua stack has space for at least `sz` more elements.
    ///
    /// This function checks if the stack can grow to accommodate the specified
    /// number of additional elements. Returns an error if the stack cannot be grown.
    ///
    /// Used internally by table operations to ensure stack safety before pushing values.
    ///
    /// Errors: `Error.OutOfMemory` if stack cannot be grown
    inline fn checkStack(self: Self, sz: i32) !void {
        if (!self.state.checkStack(sz)) {
            return Error.OutOfMemory;
        }
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

    /// Safely pops a string from the top of the Lua stack and returns an owned copy.
    ///
    /// This function addresses the garbage collection safety issue with Lua strings.
    /// Unlike `state.toString()` which returns a pointer that may become invalid after
    /// the Lua value is removed from the stack, this function creates a copy of the string
    /// using the provided allocator, then pops the value from the stack. The returned
    /// string remains valid even after the Lua value is garbage collected.
    ///
    /// The caller owns the returned memory and must free it using `allocator.free()`.
    ///
    /// Returns `null` if:
    /// - The value at the top of the stack is not a string
    /// - Memory allocation fails
    /// - The stack is empty
    ///
    /// Example:
    /// ```zig
    /// lua.push("hello world");
    /// if (lua.popString(allocator)) |owned_string| {
    ///     defer allocator.free(owned_string);
    ///     // Use owned_string safely - it's already been popped from stack
    ///     std.debug.print("String: {s}\n", .{owned_string});
    /// }
    /// ```
    pub fn popString(self: Self, allocator: std.mem.Allocator) ?[]u8 {
        const lstr = self.state.toString(-1) orelse return null;
        const copy = allocator.dupe(u8, lstr) catch null;
        self.state.pop(1);

        return copy;
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

test "Push and pop basic types" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test integers
    lua.push(@as(i32, 42));
    try expectEq(lua.pop(i32).?, 42);

    // Test floats
    lua.push(@as(f64, 3.14));
    try expectEq(lua.pop(f64).?, 3.14);

    // Test booleans
    lua.push(true);
    try expect(lua.pop(bool).?);

    try expectEq(lua.top(), 0);
}

test "Push and pop optional types" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test optional with value
    lua.push(@as(?i32, 42));
    try expectEq(lua.pop(?i32).?, 42);

    // Test optional null
    lua.push(@as(?i32, null));
    try expect(lua.pop(?i32) == null);

    try expectEq(lua.top(), 0);
}

test "Push and pop edge cases" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test zero and negative values
    lua.push(@as(i32, 0));
    try expectEq(lua.pop(i32).?, 0);

    lua.push(@as(i32, -42));
    try expectEq(lua.pop(i32).?, -42);

    // Test comptime values
    lua.push(123);
    try expectEq(lua.pop(i32).?, 123);

    try expectEq(lua.top(), 0);
}

test "Push and pop tuples" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test empty tuple
    lua.push(.{});
    try expectEq(lua.top(), 0); // Empty tuple pushes nothing

    // Test multiple element tuple
    lua.push(.{ 123, 3.14, true });
    try expect(lua.pop(bool).?); // Last element (top of stack)
    try expectEq(lua.pop(f32).?, 3.14); // Second element
    try expectEq(lua.pop(i32).?, 123); // First element

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

test "Push functions" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test Zig function
    lua.push(testAdd);
    try expect(lua.state.isFunction(-1));
    try expect(lua.state.isCFunction(-1)); // Zig functions are wrapped as C functions
    lua.state.pop(1);

    try expectEq(lua.top(), 0);
}

test "Call Zig function from Lua" {
    const lua = try Lua.init();
    defer lua.deinit();

    lua.setGlobal("add", testAdd);
    const sum = try lua.eval("return add(10, 20)", .{}, i32);
    try expectEq(sum, 30);
}

test "Ref types" {
    const lua = try Lua.init();
    defer lua.deinit();

    lua.push(testAdd);
    const ref = lua.createRef(-1);
    defer ref.deinit();

    try expect(ref.isValid());
    try expect(ref.isFunction());
    try expect(!ref.isTable());

    lua.state.pop(1);
    try expectEq(lua.top(), 0);
}

test "Push Ref to stack" {
    const lua = try Lua.init();
    defer lua.deinit();

    lua.push(testAdd);
    const ref = lua.createRef(-1);
    defer ref.deinit();

    lua.state.pop(1);
    lua.push(ref);
    try expect(lua.state.isFunction(-1));

    lua.state.pop(1);
    try expectEq(lua.top(), 0);
}

test "Global variables" {
    const lua = try Lua.init();
    defer lua.deinit();

    lua.setGlobal("x", 42);
    try expectEq(lua.getGlobal("x", i32).?, 42);

    lua.setGlobal("flag", true);
    try expect(lua.getGlobal("flag", bool).?);

    try expect(lua.getGlobal("nonexistent", i32) == null);

    try expectEq(lua.top(), 0);
}

test "Eval function" {
    const lua = try Lua.init();
    defer lua.deinit();

    const result = try lua.eval("return 2 + 3", .{}, i32);
    try expectEq(result, 5);

    try lua.eval("x = 42", .{}, void);
    try expectEq(lua.getGlobal("x", i32).?, 42);

    try expectEq(lua.top(), 0);
}

test "Compilation error handling" {
    const lua = try Lua.init();
    defer lua.deinit();

    const compile_error = lua.eval("return 1 + '", .{}, i32);
    try expect(compile_error == Error.Compile);

    try expectEq(lua.top(), 0);
}

test "String support" {
    const lua = try Lua.init();
    defer lua.deinit();

    lua.push("hello");
    try expect(lua.state.isString(-1));
    lua.state.pop(1);

    lua.setGlobal("message", "world");
    _ = lua.state.getGlobal("message");
    try expect(std.mem.eql(u8, lua.state.toString(-1).?, "world"));
    lua.state.pop(1);

    try expectEq(lua.top(), 0);
}

test "Safe string handling with allocator" {
    const lua = try Lua.init();
    defer lua.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    lua.push("hello world");
    const str = lua.popString(allocator).?;
    defer allocator.free(str);
    try expect(std.mem.eql(u8, str, "hello world"));

    try expectEq(lua.top(), 0);
}

test "Table basic operations" {
    const lua = try Lua.init();
    defer lua.deinit();

    const table = lua.createTable(0, 0);
    defer table.deinit();

    // Test raw operations (bypass metamethods)
    try table.setRaw(1, 42);
    try expectEq(try table.getRaw(1, i32), 42);

    try table.setRaw(2, true);
    try expectEq(try table.getRaw(2, bool), true);

    // Test non-raw operations (invoke metamethods)
    try table.set("key", 123);
    try expectEq(try table.get("key", i32), 123);

    try table.set("flag", false);
    try expectEq(try table.get("flag", bool), false);

    // Test non-existent keys
    try expectEq(try table.getRaw(999, i32), null);
    try expectEq(try table.get("missing", i32), null);

    try expectEq(lua.top(), 0);
}

test "Push Table to stack" {
    const lua = try Lua.init();
    defer lua.deinit();

    const table = lua.createTable(0, 0);
    defer table.deinit();

    // Set a value in the table
    try table.set("test", 42);

    // Push the table onto the stack
    lua.push(table);
    try expectEq(lua.top(), 1);
    try expect(lua.state.isTable(-1));

    // Verify we can access the table value through the pushed table
    lua.push("test");
    _ = lua.state.getTable(-2);
    try expectEq(lua.pop(i32), 42);

    lua.state.pop(1); // Pop the table
    try expectEq(lua.top(), 0);
}
