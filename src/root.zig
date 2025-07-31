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

    /// Enable Luau's JIT code generator for improved function execution performance.
    ///
    /// This method checks if code generation is supported on the current platform and
    /// initializes the code generator if available. Once enabled, functions can be
    /// compiled to native machine code using `Function.compile()`.
    ///
    /// The code generator provides significant performance improvements for
    /// compute-intensive Lua functions by compiling them to native machine code
    /// instead of interpreting bytecode.
    ///
    /// Returns:
    /// - `true` if codegen is supported and was successfully enabled
    /// - `false` if codegen is not supported on this platform
    ///
    /// Notes:
    /// - Should only be called once per Lua state
    /// - Safe to call multiple times (subsequent calls are no-ops)
    /// - Must be called before using `Function.compile()`
    ///
    /// Example:
    /// ```zig
    /// const lua = try Lua.init();
    /// defer lua.deinit();
    ///
    /// if (lua.enable_codegen()) {
    ///     // Code generation is now available
    ///     // Functions can be compiled with func.compile()
    /// } else {
    ///     // Code generation not supported, functions will use interpreter
    /// }
    /// ```
    pub fn enable_codegen(self: Self) bool {
        if (State.codegenSupported()) {
            State.codegenCreate(self.state);
            return true;
        }

        return false;
    }

    /// A reference to a Lua value.
    ///
    /// Holds a reference ID that can be used to retrieve the value later.
    /// Must be explicitly released using deinit() to avoid memory leaks.
    pub const Ref = struct {
        lua: Lua,
        ref: c_int,

        /// Releases the Lua reference, allowing the referenced value to be garbage collected.
        ///
        /// Note: For references obtained from `globals()`, calling `deinit()` is not required
        /// and will be a no-op since the globals table is a special pseudo-index that doesn't
        /// need explicit memory management.
        pub fn deinit(self: Ref) void {
            if (self.ref != State.GLOBALSINDEX) {
                self.lua.state.unref(self.ref);
            }
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
        /// Both keys and values support automatic type conversion:
        /// - Keys: Integers, floats, booleans, strings, optionals, functions, references
        /// - Values: All types supported by the type system (integers, floats, booleans,
        ///   strings, optionals, tuples, vectors, functions, references, tables)
        ///
        /// Examples:
        /// ```zig
        /// // Basic key-value pairs
        /// try table.set("name", "Alice");         // String key, string value
        /// try table.set(42, "answer");            // Integer key, string value
        /// try table.set(true, 100);               // Boolean key, integer value
        /// try table.set(3.14, "pi");              // Float key, string value
        ///
        /// // Complex value types
        /// try table.set("coords", .{10, 20, 30}); // Tuple becomes nested table
        /// try table.set("flag", @as(?bool, null)); // Optional null becomes nil
        /// try table.set("vector", @Vector(3, f32){1, 2, 3}); // Luau vector
        ///
        /// // Function values
        /// fn helper() i32 { return 42; }
        /// try table.set("helper", helper);        // Store function in table
        ///
        /// // Nested tables
        /// const inner = lua.createTable(0, 2);
        /// defer inner.deinit();
        /// try inner.set("x", 5);
        /// try table.set("inner", inner);          // Store table in table
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
        /// Keys support automatic type conversion (integers, floats, booleans, strings, etc.).
        /// Values are converted from Lua to the requested Zig type with support for:
        /// - Lua boolean → `bool`
        /// - Lua number/integer → Integer types (`i8`, `i32`, `i64`, etc.)
        /// - Lua number → Float types (`f32`, `f64`)
        /// - Lua vector → Vector types (`@Vector(N, f32)`)
        /// - Lua nil → Optional types (`?T`) as `null`
        /// - Any valid value → Optional types (`?T`) as wrapped value
        ///
        /// Returns `null` if the key doesn't exist or the value cannot be converted to type `T`.
        ///
        /// Note: String conversion is not supported via `get` due to Lua's garbage collection.
        /// For safe string handling, use Lua code with `eval()` or the low-level State API.
        ///
        /// Examples:
        /// ```zig
        /// // Basic type retrieval
        /// const name = try table.get("name", i32);    // Get integer value
        /// const answer = try table.get(42, f64);      // Get float value
        /// const flag = try table.get(true, bool);     // Get boolean value
        /// const pos = try table.get("pos", @Vector(3, f32)); // Get vector value
        ///
        /// // Optional types (handle missing values gracefully)
        /// const maybe_value = try table.get("missing", ?i32);  // null if missing
        /// const nullable = try table.get("nil_field", ?i32);   // null if nil
        ///
        /// // Different key types
        /// const by_string = try table.get("key", i32);     // String key
        /// const by_number = try table.get(42, i32);        // Integer key
        /// const by_float = try table.get(3.14, i32);       // Float key
        /// const by_bool = try table.get(true, i32);        // Boolean key
        ///
        /// // Working with nested structures
        /// // After: table.set("coords", .{10, 20, 30})
        /// // The tuple becomes a nested table accessible by index
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

        /// Calls a function stored in the table.
        ///
        /// Retrieves a function from the table using the provided key and calls it with the given arguments.
        /// The function must exist in the table and be callable, otherwise the call will fail.
        ///
        /// Examples:
        /// ```zig
        /// // Call a function with no arguments
        /// const result = try table.call("myFunc", .{}, i32);
        ///
        /// // Call a function with multiple arguments
        /// const result = try table.call("add", .{10, 20}, i32);
        ///
        /// // Call a function returning multiple values
        /// const result = try table.call("getCoords", .{}, struct { f64, f64 });
        /// ```
        ///
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn call(self: Table, key: anytype, args: anytype, comptime R: type) !R {
            try self.ref.lua.checkStack(3);

            self.ref.lua.push(self.ref); // Push table ref
            self.ref.lua.push(key); // Push key
            _ = self.ref.lua.state.getTable(-2); // Get function from table, pop key

            defer self.ref.lua.state.pop(-1); // Pop table in the end.

            return self.ref.lua.call(args, R);
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
    /// const table = lua.createTable(.{});
    /// defer table.deinit();
    ///
    /// // Create table expecting 10 array elements
    /// const array_table = lua.createTable(.{ .arr = 10 });
    /// defer array_table.deinit();
    ///
    /// // Create table expecting 5 hash elements
    /// const hash_table = lua.createTable(.{ .rec = 5 });
    /// defer hash_table.deinit();
    ///
    /// // Create table expecting both array and hash elements
    /// const mixed_table = lua.createTable(.{ .arr = 10, .rec = 5 });
    /// defer mixed_table.deinit();
    /// ```
    ///
    /// Returns: `Table` - A wrapper around the newly created Lua table
    pub inline fn createTable(self: Self, opts: struct { arr: u32 = 0, rec: u32 = 0 }) Table {
        self.state.createTable(opts.arr, opts.rec);
        defer self.state.pop(1);

        return Table{ .ref = self.createRef(-1) };
    }

    /// Returns a table wrapper for the Lua global environment.
    ///
    /// Provides access to the global table (_G) where all global variables are stored.
    /// This is the primary way to interact with global variables in the Lua environment.
    ///
    /// The returned table supports all standard table operations:
    /// - `set(key, value)` - Set global variables with full Lua semantics
    /// - `get(key, T)` - Get global variables with automatic type conversion
    /// - `setRaw(index, value)` - Set by integer index (bypass metamethods)
    /// - `getRaw(index, T)` - Get by integer index (bypass metamethods)
    ///
    /// Memory management: The globals table reference does not need to be explicitly
    /// released with `deinit()` as it's a special pseudo-index, but calling `deinit()`
    /// is safe and will be a no-op.
    ///
    /// Examples:
    /// ```zig
    /// const globals = lua.globals();
    ///
    /// // Set global variables
    /// try globals.set("x", 42);
    /// try globals.set("message", "hello");
    /// try globals.set("coords", .{10, 20, 30});
    ///
    /// // Get global variables
    /// const x = try globals.get("x", i32);           // Returns 42
    /// const missing = try globals.get("missing", ?i32); // Returns null
    ///
    /// // Access from Lua code
    /// try lua.eval("print(x)", .{}, void);           // Prints: 42
    /// try lua.eval("print(message)", .{}, void);     // Prints: hello
    ///
    /// // Functions are also globals
    /// fn add(a: i32, b: i32) i32 { return a + b; }
    /// try globals.set("add", add);
    /// const sum = try lua.eval("return add(5, 3)", .{}, i32); // Returns 8
    /// ```
    ///
    /// Returns: `Table` - A wrapper around the Lua global environment table
    pub inline fn globals(self: Self) Table {
        return Table{
            .ref = Ref{ .lua = self, .ref = State.GLOBALSINDEX },
        };
    }

    /// High-level function wrapper providing access to Lua functions.
    ///
    /// Holds a reference to a Lua function and provides methods for calling the function
    /// with automatic type conversion. This is an alternative to using `Table.call("funcName", ...)`
    /// when you have a direct reference to the function.
    ///
    /// The Function reference must be explicitly released using `deinit()` to avoid memory leaks.
    ///
    /// Examples:
    /// ```zig
    /// // Get function from global namespace
    /// _ = try lua.eval("function multiply(a, b) return a * b end", .{}, void);
    /// const globals = lua.globals();
    /// const func = try globals.get("multiply", Lua.Function);
    /// defer func.?.deinit(); // Must call deinit to release reference
    ///
    /// // Call function with arguments
    /// const result = try func.?.call(.{6, 7}, i32); // Returns 42
    ///
    /// // Alternative to Table.call approach:
    /// // const result = try globals.call("multiply", .{6, 7}, i32);
    /// ```
    pub const Function = struct {
        ref: Ref,

        pub fn deinit(self: Function) void {
            self.ref.deinit();
        }

        /// Calls the function with the provided arguments and returns the result.
        ///
        /// Pushes the function onto the stack, followed by the arguments, then calls the function
        /// and returns the result converted to the specified type.
        ///
        /// Examples:
        /// ```zig
        /// // Call a function with no arguments
        /// const result = try func.call(.{}, i32);
        ///
        /// // Call a function with multiple arguments
        /// const result = try func.call(.{10, 20}, i32);
        ///
        /// // Call a function returning multiple values
        /// const result = try func.call(.{}, struct { f64, f64 });
        /// ```
        ///
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn call(self: @This(), args: anytype, comptime R: type) !R {
            try self.ref.lua.checkStack(2);

            self.ref.lua.push(self.ref); // Push function ref

            return self.ref.lua.call(args, R);
        }

        /// Compile this function using Luau's JIT code generator for improved performance.
        ///
        /// This method compiles the function (and any nested functions it contains) to native
        /// machine code using Luau's code generator. Compiled functions execute significantly
        /// faster than interpreted bytecode.
        ///
        /// Prerequisites:
        /// - `enable_codegen()` must be called successfully first
        ///
        /// Notes:
        /// - This is a one-time operation - functions remain compiled for their lifetime
        /// - Compilation happens immediately and synchronously
        /// - Nested functions within this function are also compiled
        /// - Has no effect if the function is already compiled
        ///
        /// Example:
        /// ```zig
        /// // Enable code generator
        /// if (lua.enable_codegen()) {
        ///     // Load a function and get reference
        ///     _ = try lua.eval("function fibonacci(n) return n < 2 and n or fibonacci(n-1) + fibonacci(n-2) end", .{}, void);
        ///     const globals = lua.globals();
        ///     const fib = try globals.get("fibonacci", Lua.Function);
        ///     defer fib.?.deinit();
        ///
        ///     // Compile for better performance
        ///     fib.?.compile();
        ///
        ///     // Function calls now use compiled native code
        ///     const result = try fib.?.call(.{10}, i32);
        /// }
        /// ```
        pub fn compile(self: @This()) void {
            self.ref.lua.push(self.ref); // Push function ref
            defer self.ref.lua.state.pop(1); // Remove from stack

            self.ref.lua.state.codegenCompile(-1);
        }

        /// Returns the registry reference ID if valid, otherwise null.
        inline fn getRef(self: Function) ?c_int {
            return self.ref.getRef();
        }
    };

    /// Internal function to push a Zig value onto the Lua stack.
    /// Used internally by table operations and other high-level functions.
    fn push(self: Self, value: anytype) void {
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
                // Tuples are represented as indexed tables (arrays).
                // Each tuple element is accessible by index starting from 1 (Lua convention).
                if (info.is_tuple) {
                    self.state.createTable(@intCast(info.fields.len), 0);
                    inline for (info.fields, 0..) |_, i| {
                        self.push(value[i]);
                        self.state.rawSetI(-2, @intCast(i + 1)); // Set table[i+1] = value, pop value
                    }

                    break :blk;
                }

                // Handle Ref and Table types
                if (T == Ref or T == Table or T == Function) {
                    // Push reference to stack
                    if (value.getRef()) |index| {
                        if (index != State.GLOBALSINDEX) {
                            _ = self.state.rawGetI(State.REGISTRYINDEX, index);
                        } else {
                            // Globals table is a special pseudo-index, push it directly
                            self.state.pushValue(index);
                        }
                    } else {
                        self.state.pushNil();
                    }

                    break :blk;
                }

                @compileError("Non tuple structs are not yet implemented");
            },
            .vector => |vector_info| {
                // Use Luau's native vector support
                if (vector_info.child != f32) {
                    @compileError("Luau vectors only support f32 elements, got " ++ @typeName(vector_info.child));
                }

                // Only support vectors of LUA_VECTOR_SIZE
                if (vector_info.len != State.VECTOR_SIZE) {
                    @compileError("Luau configured for " ++
                        std.fmt.comptimePrint("{d}", .{State.VECTOR_SIZE}) ++
                        "-component vectors, but got " ++
                        std.fmt.comptimePrint("{d}", .{vector_info.len}) ++
                        "-component vector");
                }

                // Convert Zig vector to array for pushVector
                const vec_array: [State.VECTOR_SIZE]f32 = @bitCast(value);
                self.state.pushVector(vec_array);
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
                            args[i] = lua.checkArg(i + 1, field.type);
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

    /// Internal function to pop a value from the Lua stack and convert it to a Zig type.
    /// Used internally by table operations and other high-level functions.
    inline fn pop(self: Self, comptime T: type) ?T {
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
    fn checkArg(self: Self, index: i32, comptime T: type) T {
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
                    self.checkArg(index, type_info.optional.child);
            },
            .vector => |info| {
                if (info.child != f32) {
                    @compileError("Luau vectors only support f32 elements, got " ++ @typeName(info.child));
                }

                // Only support vectors of LUA_VECTOR_SIZE
                if (info.len != State.VECTOR_SIZE) {
                    @compileError("Luau configured for " ++
                        std.fmt.comptimePrint("{d}", .{State.VECTOR_SIZE}) ++
                        "-component vectors, but got " ++
                        std.fmt.comptimePrint("{d}", .{info.len}) ++
                        "-component vector");
                }

                const lua_vec = self.state.checkVector(index);

                if (State.VECTOR_SIZE == 4) {
                    return @Vector(4, f32){ lua_vec[0], lua_vec[1], lua_vec[2], lua_vec[3] };
                } else {
                    return @Vector(3, f32){ lua_vec[0], lua_vec[1], lua_vec[2] };
                }
            },
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .slice => {
                        // Handle string slices: []const u8, [:0]const u8
                        if (ptr_info.child == u8) {
                            const lua_str = self.state.checkString(index);

                            // Return appropriate slice type
                            if (comptime std.mem.indexOf(u8, @typeName(T), ":0") != null) {
                                // Zero-terminated slice: [:0]const u8
                                return lua_str;
                            } else {
                                // Regular slice: []const u8
                                return lua_str[0..lua_str.len];
                            }
                        }

                        @compileError("Unable to check type " ++ @typeName(T));
                    },
                    else => @compileError("Unable to check type " ++ @typeName(T)),
                }
            },
            else => {
                @compileError("Unable to check type " ++ @typeName(T));
            },
        }
    }

    /// Internal function to convert a single Lua value at the specified stack index to a Zig type.
    ///
    /// This function always expects to handle exactly one Lua stack slot and does not handle composite types like tuples.
    /// For composite types, use higher-level functions that manage multiple stack slots appropriately.
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
            .vector => |info| {
                if (info.child != f32) {
                    @compileError("Luau vectors only support f32 elements, got " ++ @typeName(info.child));
                }

                // Only support vectors of LUA_VECTOR_SIZE
                if (info.len != State.VECTOR_SIZE) {
                    @compileError("Luau configured for " ++
                        std.fmt.comptimePrint("{d}", .{State.VECTOR_SIZE}) ++
                        "-component vectors, but got " ++
                        std.fmt.comptimePrint("{d}", .{info.len}) ++
                        "-component vector");
                }

                if (!self.state.isVector(index)) {
                    return null;
                }

                const lua_vec = self.state.toVector(index) orelse return null;

                return if (State.VECTOR_SIZE == 4)
                    @Vector(4, f32){ lua_vec[0], lua_vec[1], lua_vec[2], lua_vec[3] }
                else
                    @Vector(3, f32){ lua_vec[0], lua_vec[1], lua_vec[2] };
            },
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .slice => {
                        // Handle string slices: []const u8, [:0]const u8
                        if (ptr_info.child == u8) {
                            // Check if the value is actually a string to avoid conversion
                            // Use getType instead of isString because isString returns true for numbers too
                            if (self.state.getType(index) != .string) {
                                return null;
                            }

                            const lua_str = self.state.toString(index) orelse return null;

                            // Return appropriate slice type
                            if (comptime std.mem.indexOf(u8, @typeName(T), ":0") != null) {
                                // Zero-terminated slice: [:0]const u8
                                return lua_str;
                            } else {
                                // Regular slice: []const u8 - convert from [:0]const u8 to []const u8
                                return lua_str[0..lua_str.len];
                            }
                        }

                        return null;
                    },
                    else => return null,
                }
            },
            .@"struct" => {
                // Handle reference types: Ref, Table, Function
                if (T == Ref) {
                    // Create a reference to any value on the stack
                    return self.createRef(index);
                } else if (T == Table) {
                    // Create a Table reference if the value is a table
                    if (!self.state.isTable(index)) {
                        return null;
                    }
                    return Table{ .ref = self.createRef(index) };
                } else if (T == Function) {
                    // Create a Function reference if the value is a function
                    if (!self.state.isFunction(index)) {
                        return null;
                    }
                    return Function{ .ref = self.createRef(index) };
                }

                @compileError("Unsupported struct type " ++ @typeName(T));
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
    /// - `struct { T1, T2, ... }` - Tuple types for multiple return values
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
    ///
    /// // Execute bytecode that returns multiple values as a tuple
    /// const tuple = try lua.exec(bytecode, struct { i32, f64, bool });
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

        return self.call(.{}, T);
    }

    fn call(self: Self, args: anytype, comptime R: type) R {
        // Count and push args.
        const arg_count = blk: {
            const args_type_info = @typeInfo(@TypeOf(args));
            switch (args_type_info) {
                .void => break :blk 0,
                .@"struct" => |info| {
                    if (info.is_tuple) {
                        // Push tuple elements in order
                        inline for (args) |arg| {
                            self.push(arg);
                        }
                        break :blk @as(u32, @intCast(info.fields.len));
                    } else {
                        self.push(args);
                        break :blk 1;
                    }
                },
                else => {
                    self.push(args);
                    break :blk 1;
                },
            }
        };

        // Count how many ret args to expect
        const ret_count = blk: {
            const ret_type_info = @typeInfo(R);
            switch (ret_type_info) {
                .void => break :blk 0,
                .@"struct" => |info| break :blk if (info.is_tuple) @as(i32, @intCast(info.fields.len)) else 1,
                else => break :blk 1,
            }
        };

        self.state.call(arg_count, ret_count);

        // Fetch ret args
        const ret_type_info = @typeInfo(R);
        if (ret_type_info == .void) {
            return;
        } else if (ret_type_info == .@"struct") {
            const info = ret_type_info.@"struct";
            if (info.is_tuple) {
                var result: R = undefined;
                // Pop tuple elements in reverse order (stack is LIFO)
                inline for (0..info.fields.len) |i| {
                    const field_index = info.fields.len - 1 - i;
                    result[field_index] = self.pop(info.fields[field_index].type).?;
                }
                return result;
            }
        }
        return self.pop(R).?;
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
    /// - `struct { T1, T2, ... }` - Tuple types for multiple return values
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
    /// const result = try lua.eval("return math.sqrt(16)", .{ .opt_level = 2 }, f64);
    ///
    /// // Execute with optional return type
    /// const maybe_result = try lua.eval("return getValue()", .{}, ?i32);
    ///
    /// // Execute code that returns multiple values as a tuple
    /// const tuple = try lua.eval("return 42, 3.14, true", .{}, struct { i32, f64, bool });
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

    /// Dump the current stack contents to a string for debugging
    ///
    /// Creates a formatted string representation of all values currently on the Lua stack,
    /// showing their stack indices, types, and string representations. Uses Lua's `toString`
    /// to convert values to strings, showing "nil" for values that cannot be converted.
    ///
    /// Format for each stack entry: `  {index} [{type}] {value}`
    ///
    /// Examples:
    /// ```zig
    /// var lua = try Lua.init();
    /// defer lua.deinit();
    ///
    /// lua.push(42.5);
    /// lua.push(true);
    /// lua.push("hello");
    /// lua.push(@as(?i32, null));
    ///
    /// const dump = try lua.dumpStack(allocator);
    /// defer allocator.free(dump);
    /// // Output:
    /// // Lua stack dump (size: 4):
    /// //   4 [nil] nil
    /// //   3 [string] hello
    /// //   2 [boolean] true
    /// //   1 [number] 42.5
    /// ```
    ///
    /// Returns: Allocated string containing the stack dump. Caller owns the memory.
    /// Errors: `std.mem.Allocator.Error` if memory allocation fails
    pub fn dumpStack(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        const writer = list.writer();
        const stack_size = self.state.getTop();

        if (stack_size == 0) {
            try writer.writeAll("Lua stack is empty\n");
        } else {
            try writer.print("Lua stack dump (size: {}):\n", .{stack_size});
        }

        var n = stack_size;
        while (n > 0) {
            const stack_type = self.state.getType(n);
            const type_name = self.state.typeName(stack_type);
            const str_value = self.state.toString(n) orelse "nil";

            try writer.print("  {} [{s}] {s}\n", .{ n, type_name, str_value });

            n -= 1;
        }

        return list.toOwnedSlice();
    }
};

const expect = std.testing.expect;
const expectEq = std.testing.expectEqual;

test "push and pop basic types" {
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

test "push and pop optional types" {
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

test "push and pop edge cases" {
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

test "push and pop tuples" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test empty tuple
    lua.push(.{});
    try expectEq(lua.top(), 1); // Empty tuple creates an empty table
    try expect(lua.state.isTable(-1));
    lua.state.pop(1);

    // Test multiple element tuple - now creates a table
    lua.push(.{ 123, 3.14, true });
    try expectEq(lua.top(), 1); // Tuple creates one table
    try expect(lua.state.isTable(-1));

    // Verify elements are accessible by index (1-based)
    _ = lua.state.rawGetI(-1, 1);
    try expectEq(lua.pop(i32).?, 123); // First element at index 1

    _ = lua.state.rawGetI(-1, 2);
    try expectEq(lua.pop(f32).?, 3.14); // Second element at index 2

    _ = lua.state.rawGetI(-1, 3);
    try expect(lua.pop(bool).?); // Third element at index 3

    lua.state.pop(1); // Pop the table
    try expectEq(lua.top(), 0);
}

test "tuple as indexed table accessibility from Lua" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Push a tuple and make it available as global
    lua.push(.{ 42, 3.14, "hello", true });
    lua.state.setGlobal("tupleTable");

    // Access elements from Lua using 1-based indexing
    try expectEq(try lua.eval("return tupleTable[1]", .{}, i32), 42);
    try expectEq(try lua.eval("return tupleTable[2]", .{}, f32), 3.14);
    try expect(try lua.eval("return tupleTable[4]", .{}, bool));

    // Verify tuple table length
    try expectEq(try lua.eval("return #tupleTable", .{}, i32), 4);
}

// Test functions for function push test
fn testCFunction(state: ?State.LuaState) callconv(.C) c_int {
    _ = state;
    return 0;
}

fn testAdd(a: i32, b: i32) i32 {
    return a + b;
}

fn testTupleReturn(a: i32, b: f32) struct { i32, f32, bool } {
    return .{ a * 2, b * 2.0, a > 10 };
}

fn testStringArg(msg: []const u8) i32 {
    return @intCast(msg.len);
}

test "push functions" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test Zig function
    lua.push(testAdd);
    try expect(lua.state.isFunction(-1));
    try expect(lua.state.isCFunction(-1)); // Zig functions are wrapped as C functions
    lua.state.pop(1);

    try expectEq(lua.top(), 0);
}

test "call Zig function from Lua" {
    const lua = try Lua.init();
    defer lua.deinit();

    const globals = lua.globals();
    try globals.set("add", testAdd);
    const sum = try lua.eval("return add(10, 20)", .{}, i32);
    try expectEq(sum, 30);
}

test "call Zig function returning tuple from Lua" {
    const lua = try Lua.init();
    defer lua.deinit();

    const globals = lua.globals();
    try globals.set("tupleFunc", testTupleReturn);

    // Function returns a tuple as a table (array)
    try lua.eval("result = tupleFunc(15, 3.5)", .{}, void);

    // Verify the returned tuple is a table with indexed elements
    try expectEq(try lua.eval("return result[1]", .{}, i32), 30); // 15 * 2
    try expectEq(try lua.eval("return result[2]", .{}, f32), 7.0); // 3.5 * 2.0
    try expect(try lua.eval("return result[3]", .{}, bool)); // 15 > 10 = true
}

test "ref types" {
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

test "push ref to stack" {
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

test "global variables" {
    const lua = try Lua.init();
    defer lua.deinit();

    const globals = lua.globals();

    try globals.set("x", 42);
    try expectEq(try globals.get("x", i32), 42);

    try globals.set("flag", true);
    try expect((try globals.get("flag", bool)).?);

    try expectEq(try globals.get("nonexistent", i32), null);

    try expectEq(lua.top(), 0);
}

test "eval function" {
    const lua = try Lua.init();
    defer lua.deinit();

    const result = try lua.eval("return 2 + 3", .{}, i32);
    try expectEq(result, 5);

    try lua.eval("x = 42", .{}, void);
    const globals = lua.globals();
    try expectEq(try globals.get("x", i32), 42);

    try expectEq(lua.top(), 0);
}

test "eval function with tuple return values" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test eval with tuple return
    const tuple = try lua.eval("return 10, 2.5, false", .{}, struct { i32, f64, bool });
    try expectEq(tuple[0], 10);
    try expectEq(tuple[1], 2.5);
    try expect(!tuple[2]);

    try expectEq(lua.top(), 0);
}

test "dump stack" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test empty stack
    const empty_dump = try lua.dumpStack(std.testing.allocator);
    defer std.testing.allocator.free(empty_dump);
    try expect(std.mem.indexOf(u8, empty_dump, "Lua stack is empty") != null);

    // Test stack with values
    lua.push(@as(f64, 42.5));
    lua.push(true);
    lua.push("hello");
    lua.push(@as(?i32, null));

    const stack_size_before = lua.top();

    try expectEq(stack_size_before, 4);

    const dump = try lua.dumpStack(std.testing.allocator);
    defer std.testing.allocator.free(dump);

    try expectEq(lua.top(), stack_size_before);

    try expect(std.mem.indexOf(u8, dump, "Lua stack dump (size: 4)") != null);
    try expect(std.mem.indexOf(u8, dump, "42.5") != null);
    try expect(std.mem.indexOf(u8, dump, "hello") != null);
    try expect(std.mem.indexOf(u8, dump, "nil") != null);
}

test "compilation error handling" {
    const lua = try Lua.init();
    defer lua.deinit();

    const compile_error = lua.eval("return 1 + '", .{}, i32);
    try expect(compile_error == Error.Compile);

    try expectEq(lua.top(), 0);
}

test "string support" {
    const lua = try Lua.init();
    defer lua.deinit();

    lua.push("hello");
    try expect(lua.state.isString(-1));
    lua.state.pop(1);

    const globals = lua.globals();
    try globals.set("message", "world");
    _ = lua.state.getGlobal("message");
    try expect(std.mem.eql(u8, lua.state.toString(-1).?, "world"));
    lua.state.pop(1);

    try expectEq(lua.top(), 0);
}

test "table basic operations" {
    const lua = try Lua.init();
    defer lua.deinit();

    const table = lua.createTable(.{});
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

test "push table to stack" {
    const lua = try Lua.init();
    defer lua.deinit();

    const table = lua.createTable(.{});
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

test "table call function" {
    const lua = try Lua.init();
    defer lua.deinit();

    _ = try lua.eval(
        \\function add(a, b) return a + b end
    , .{}, void);

    const globals = lua.globals();

    const result = try globals.call("add", .{ 10, 20 }, i32);
    try expectEq(result, 30);
    try expectEq(lua.top(), 0);
}

test "push and pop vector types" {
    const lua = try Lua.init();
    defer lua.deinit();

    const vec3 = @Vector(3, f32){ 1.0, 2.0, 3.0 };
    lua.push(vec3);
    try expect(lua.state.isVector(-1));
    const popped_vec3 = lua.pop(@Vector(3, f32)).?;
    try expectEq(popped_vec3[0], 1.0);
    try expectEq(popped_vec3[1], 2.0);
    try expectEq(popped_vec3[2], 3.0);

    try expectEq(lua.top(), 0);
}

test "globals table access" {
    const lua = try Lua.init();
    defer lua.deinit();

    const globals = lua.globals();

    // Set values through the globals table
    try globals.set("testValue", 42);
    try globals.set("testFlag", true);

    // Access the same values through the globals table
    try expectEq(try globals.get("testValue", i32), 42);
    try expectEq(try globals.get("testFlag", bool), true);

    // Set more values through the globals table
    try globals.set("newValue", 123);
    try globals.set("newFlag", false);

    // Verify through Lua eval
    try expectEq(try lua.eval("return newValue", .{}, i32), 123);
    try expectEq(try lua.eval("return newFlag", .{}, bool), false);

    try expectEq(lua.top(), 0);
}

test "string to value" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Test string retrieval
    lua.push("hello world");
    const str_slice = lua.toValue([]const u8, -1);
    try expect(str_slice != null);
    try expect(std.mem.eql(u8, str_slice.?, "hello world"));
    lua.state.pop(1);

    // Test that numbers don't get converted to strings
    lua.push(@as(i32, 42));
    const not_string = lua.toValue([]const u8, -1);
    try expect(not_string == null);
    lua.state.pop(1);

    try expectEq(lua.top(), 0);
}

test "string arguments in Zig functions" {
    const lua = try Lua.init();
    defer lua.deinit();

    const globals = lua.globals();
    try globals.set("strlen", testStringArg);

    const len = try lua.eval("return strlen('hello')", .{}, i32);
    try expectEq(len, 5);
}

test "function call from global namespace" {
    const lua = try Lua.init();
    defer lua.deinit();

    _ = try lua.eval(
        \\function sum(a, b) return a + b end
    , .{}, void);

    const globals = lua.globals();
    const func = try globals.get("sum", Lua.Function);
    try expect(func != null);
    defer func.?.deinit();

    const result = try func.?.call(.{ 15, 25 }, i32);
    try expectEq(result, 40);
    try expectEq(lua.top(), 0);
}

test "function compile" {
    const lua = try Lua.init();
    defer lua.deinit();

    // Enable code generator if supported
    if (lua.enable_codegen()) {
        // Load a simple function
        _ = try lua.eval("function multiply(a, b) return a * b end", .{}, void);
        const globals = lua.globals();
        const func = try globals.get("multiply", Lua.Function);
        try expect(func != null);
        defer func.?.deinit();

        // Compile for better performance
        func.?.compile();

        // Function calls now use compiled native code
        const result = try func.?.call(.{ 6, 7 }, i32);
        try expectEq(result, 42);
        try expectEq(lua.top(), 0);
    }
}
