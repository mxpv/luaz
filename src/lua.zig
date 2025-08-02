//! **luaz** - Zero-cost wrapper library for Luau written in Zig
//!
//! This library provides idiomatic Zig bindings for the Luau scripting language,
//! focusing on Luau's unique features and performance characteristics. It offers
//! a high-level API with automatic type conversions while maintaining access to
//! low-level operations when needed.
//!
//! ## Quick Start
//!
//! To get started, a new `Lua` object must be created. The `Lua` struct provides a
//! high-level API to Luau functionality.
//!
//! For convenience, `Lua` offers an `eval` function to convert Lua source code to
//! Luau bytecode and execute it immediately. However, this compilation step should
//! ideally be taken offline as it's resource-consuming.
//!
//! ```zig
//! const std = @import("std");
//! const luaz = @import("luaz");
//!
//! pub fn main() !void {
//!     // Initialize Lua state
//!     const lua = try luaz.Lua.init(null);
//!     defer lua.deinit();
//!
//!     // Execute Lua code
//!     const result = try lua.eval("return 2 + 3", .{}, i32);
//!     std.debug.print("Result: {}\n", .{result}); // Prints: Result: 5
//!
//!     // Work with global variables
//!     const globals = lua.globals();
//!     try globals.set("message", "Hello from Zig!");
//!     try lua.eval("print(message)", .{}, void);
//!
//!     // Register Zig functions
//!     fn add(a: i32, b: i32) i32 { return a + b; }
//!     try globals.set("add", add);
//!     const sum = try lua.eval("return add(10, 20)", .{}, i32);
//! }
//! ```

const std = @import("std");
const ArgsTuple = std.meta.ArgsTuple;
const Allocator = std.mem.Allocator;

pub const State = @import("state.zig").State;
pub const Compiler = @import("compile.zig").Compiler;
const userdata = @import("userdata.zig");
const stack = @import("stack.zig");
const alloc = @import("alloc.zig").alloc;

/// High-level Lua wrapper and main library entry point.
/// Provides an idiomatic Zig interface with automatic type conversions for the Luau scripting language.
/// This is the primary API for most use cases, offering zero-cost abstractions over the low-level State API.
pub const Lua = struct {
    const Self = @This();

    state: State,

    /// Error types that can be returned by Lua operations.
    pub const Error = error{
        /// VM memory allocation failed.
        OutOfMemory,
        /// Lua source code compilation failed.
        Compile,
    };

    /// Initialize a new Lua state with optional custom allocator.
    /// ---
    /// Creates a new Luau virtual machine instance. Pass `null` to use Luau's built-in
    /// default allocator (malloc), or `&allocator` to use a custom Zig allocator. The allocator must
    /// remain valid for the entire lifetime of the Lua state.
    /// ---
    /// Note: Uses pointer parameter (`?*const Allocator`) due to C interop requirements,
    /// deviating from typical Zig conventions.
    /// ---
    /// Examples:
    /// ```zig
    /// const lua = try Lua.init(null);                   // Luau default (malloc)
    /// const lua = try Lua.init(&std.testing.allocator); // Custom allocator
    /// defer lua.deinit();
    /// ```
    /// ---
    /// Returns `Lua` instance or `Error.OutOfMemory` on failure.
    pub fn init(allocator: ?*const Allocator) !Self {
        const state = if (allocator) |alloc_ptr|
            State.initWithAlloc(alloc, @constCast(alloc_ptr))
        else
            State.init();

        return Lua{ .state = state orelse return error.OutOfMemory };
    }

    pub inline fn fromState(state: State.LuaState) Self {
        return Self{
            .state = State{ .lua = state },
        };
    }

    /// Deinitializes the Lua state and releases all associated resources.
    /// Must be called when the Lua instance is no longer needed to prevent memory leaks.
    /// NOTE: this should not be called from inside Lua callbacks.
    pub fn deinit(self: Lua) void {
        self.state.deinit();
    }

    /// Enable Luau's JIT code generator for improved function execution performance.
    /// ---
    /// This method checks if code generation is supported on the current platform and
    /// initializes the code generator if available. Once enabled, functions can be
    /// compiled to native machine code using `Function.compile()`.
    /// ---
    /// The code generator provides significant performance improvements for
    /// compute-intensive Lua functions by compiling them to native machine code
    /// instead of interpreting bytecode.
    /// ---
    /// Returns:
    /// - `true` if codegen is supported and was successfully enabled
    /// - `false` if codegen is not supported on this platform
    /// ---
    /// Notes:
    /// - Should only be called once per Lua state
    /// - Safe to call multiple times (subsequent calls are no-ops)
    /// - Must be called before using `Function.compile()`
    /// ---
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
    /// ---
    /// Holds a reference ID that can be used to retrieve the value later.
    /// Must be explicitly released using deinit() to avoid memory leaks.
    pub const Ref = struct {
        lua: Lua,
        ref: c_int,

        /// Creates a reference to a value on the stack.
        /// ---
        /// Does not consume the value.
        pub inline fn init(lua: Lua, index: i32) Ref {
            return Ref{
                .lua = lua,
                .ref = lua.state.ref(index),
            };
        }

        /// Releases the Lua reference, allowing the referenced value to be garbage collected.
        /// ---
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
        pub inline fn getRef(self: Ref) ?c_int {
            return if (self.isValid()) self.ref else null;
        }
    };

    /// table values with automatic type conversion. Must be explicitly released
    /// using deinit() to avoid memory leaks.
    pub const Table = struct {
        ref: Ref,

        /// Returns the underlying Lua state for direct state operations.
        inline fn state(self: Table) State {
            return self.ref.lua.state;
        }

        /// Releases the table reference, allowing the table to be garbage collected.
        pub fn deinit(self: Table) void {
            self.ref.deinit();
        }

        /// Sets a table element by integer index using raw access (bypasses `__newindex` metamethod).
        /// ---
        /// Directly assigns `table[index] = value` without invoking metamethods.
        /// This is faster than `set()` but doesn't respect custom table behavior.
        /// ---
        /// Examples:
        /// ```zig
        /// try table.setRaw(1, 42);        // table[1] = 42
        /// try table.setRaw(5, "hello");   // table[5] = "hello"
        /// try table.setRaw(-1, true);     // table[-1] = true
        /// ```
        /// ---
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn setRaw(self: Table, index: i32, value: anytype) !void {
            try self.ref.lua.checkStack(2);

            stack.push(self.ref.lua, self.ref); // Push table ref
            stack.push(self.ref.lua, value); // Push value
            self.state().rawSetI(-2, index); // Set table and pop value
            self.state().pop(1); // Pop table
        }

        /// Gets a table element by integer index using raw access (bypasses __index metamethod).
        /// ---
        /// Directly retrieves `table[index]` without invoking metamethods.
        /// This is faster than `get()` but doesn't respect custom table behavior.
        /// ---
        /// Returns `null` if the index doesn't exist or the value cannot be converted to type `T`.
        /// ---
        /// Examples:
        /// ```zig
        /// const value = try table.getRaw(1, i32);     // Get table[1] as i32
        /// const text = try table.getRaw(5, []u8);     // Get table[5] as string
        /// const flag = try table.getRaw(-1, bool);    // Get table[-1] as bool
        /// ```
        /// ---
        /// Returns: `?T` - The converted value, or `null` if not found or conversion failed
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn getRaw(self: Table, index: i32, comptime T: type) !?T {
            try self.ref.lua.checkStack(2);

            stack.push(self.ref.lua, self.ref); // Push table ref
            _ = self.state().rawGetI(-1, index); // Push value of t[i] onto stack.

            defer self.state().pop(1); // Pop table

            return stack.pop(self.ref.lua, T);
        }

        /// Sets a table element by key with full Lua semantics (invokes __newindex metamethod).
        /// ---
        /// Assigns `table[key] = value` following Lua's complete access protocol.
        /// If the table has a `__newindex` metamethod, it will be called.
        /// Use this for general table manipulation where metamethods should be honored.
        /// ---
        /// Both keys and values support automatic type conversion:
        /// - Keys: Integers, floats, booleans, strings, optionals, functions, references
        /// - Values: All types supported by the type system (integers, floats, booleans,
        ///   strings, optionals, tuples, vectors, functions, references, tables)
        /// ---
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
        /// ---
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn set(self: Table, key: anytype, value: anytype) !void {
            try self.ref.lua.checkStack(3);

            stack.push(self.ref.lua, self.ref); // Push table ref
            stack.push(self.ref.lua, key); // Push key
            stack.push(self.ref.lua, value); // Push value

            self.state().setTable(-3); // Set table[key] = value and pop key and value
            self.state().pop(1); // Pop table
        }

        /// Gets a table element by key with full Lua semantics (invokes __index metamethod).
        /// ---
        /// Retrieves `table[key]` following Lua's complete access protocol.
        /// If the table has an `__index` metamethod, it will be called.
        /// Use this for general table access where metamethods should be honored.
        /// ---
        /// Keys support automatic type conversion (integers, floats, booleans, strings, etc.).
        /// Values are converted from Lua to the requested Zig type with support for:
        /// - Lua boolean → `bool`
        /// - Lua number/integer → Integer types (`i8`, `i32`, `i64`, etc.)
        /// - Lua number → Float types (`f32`, `f64`)
        /// - Lua vector → Vector types (`@Vector(N, f32)`)
        /// - Lua nil → Optional types (`?T`) as `null`
        /// - Any valid value → Optional types (`?T`) as wrapped value
        /// ---
        /// Returns `null` if the key doesn't exist or the value cannot be converted to type `T`.
        /// ---
        /// Note: String conversion is not supported via `get` due to Lua's garbage collection.
        /// For safe string handling, use Lua code with `eval()` or the low-level State API.
        /// ---
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
        /// ---
        /// Returns: `?T` - The converted value, or `null` if not found or conversion failed
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn get(self: Table, key: anytype, comptime T: type) !?T {
            try self.ref.lua.checkStack(2);

            stack.push(self.ref.lua, self.ref); // Push table ref
            stack.push(self.ref.lua, key); // Push key

            _ = self.state().getTable(-2); // Pop key and push "table[key]" onto stack
            defer self.state().pop(1); // Pop table

            return stack.pop(self.ref.lua, T);
        }

        /// Calls a function stored in the table.
        /// ---
        /// Retrieves a function from the table using the provided key and calls it with the given arguments.
        /// The function must exist in the table and be callable, otherwise the call will fail.
        /// ---
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
        /// ---
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn call(self: Table, key: anytype, args: anytype, comptime R: type) !R {
            try self.ref.lua.checkStack(3);

            stack.push(self.ref.lua, self.ref); // Push table ref
            stack.push(self.ref.lua, key); // Push key
            _ = self.state().getTable(-2); // Get function from table, pop key

            defer self.state().pop(-1); // Pop table in the end.

            return self.ref.lua.call(args, R);
        }

        /// Returns the registry reference ID if valid, otherwise null.
        pub inline fn getRef(self: Table) ?c_int {
            return self.ref.getRef();
        }
    };

    /// Creates a new Lua table and returns a high-level Table wrapper.
    /// ---
    /// Creates an empty table with optional size hints for optimization.
    /// The hints help Lua preallocate memory for better performance:
    /// - `arr`: Expected number of array elements (sequential integer keys starting from 1)
    /// - `rec`: Expected number of hash table elements (non-sequential keys)
    /// ---
    /// The returned Table must be explicitly released using `deinit()` to avoid memory leaks.
    /// ---
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
    /// ---
    /// Returns: `Table` - A wrapper around the newly created Lua table
    pub inline fn createTable(self: Self, opts: struct { arr: u32 = 0, rec: u32 = 0 }) Table {
        self.state.createTable(opts.arr, opts.rec);
        defer self.state.pop(1);

        return Table{ .ref = Ref.init(self, -1) };
    }

    /// Returns a table wrapper for the Lua global environment.
    /// ---
    /// Provides access to the global table (_G) where all global variables are stored.
    /// This is the primary way to interact with global variables in the Lua environment.
    /// ---
    /// The returned table supports all standard table operations:
    /// - `set(key, value)` - Set global variables with full Lua semantics
    /// - `get(key, T)` - Get global variables with automatic type conversion
    /// - `setRaw(index, value)` - Set by integer index (bypass metamethods)
    /// - `getRaw(index, T)` - Get by integer index (bypass metamethods)
    /// ---
    /// Memory management: The globals table reference does not need to be explicitly
    /// released with `deinit()` as it's a special pseudo-index, but calling `deinit()`
    /// is safe and will be a no-op.
    /// ---
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
    /// ---
    /// Returns: `Table` - A wrapper around the Lua global environment table
    pub inline fn globals(self: Self) Table {
        return Table{
            .ref = Ref{ .lua = self, .ref = State.GLOBALSINDEX },
        };
    }

    /// High-level function wrapper providing access to Lua functions.
    /// ---
    /// Holds a reference to a Lua function and provides methods for calling the function
    /// with automatic type conversion. This is an alternative to using `Table.call("funcName", ...)`
    /// when you have a direct reference to the function.
    /// ---
    /// The Function reference must be explicitly released using `deinit()` to avoid memory leaks.
    /// ---
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

        /// Returns the underlying Lua state for direct state operations.
        inline fn state(self: Function) State {
            return self.ref.lua.state;
        }

        pub fn deinit(self: Function) void {
            self.ref.deinit();
        }

        /// Calls the function with the provided arguments and returns the result.
        /// ---
        /// Pushes the function onto the stack, followed by the arguments, then calls the function
        /// and returns the result converted to the specified type.
        /// ---
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
        /// ---
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn call(self: @This(), args: anytype, comptime R: type) !R {
            try self.ref.lua.checkStack(2);

            stack.push(self.ref.lua, self.ref); // Push function ref

            return self.ref.lua.call(args, R);
        }

        /// Compile this function using Luau's JIT code generator for improved performance.
        /// ---
        /// This method compiles the function (and any nested functions it contains) to native
        /// machine code using Luau's code generator. Compiled functions execute significantly
        /// faster than interpreted bytecode.
        /// ---
        /// Prerequisites:
        /// - `enable_codegen()` must be called successfully first
        /// ---
        /// Notes:
        /// - This is a one-time operation - functions remain compiled for their lifetime
        /// - Compilation happens immediately and synchronously
        /// - Nested functions within this function are also compiled
        /// - Has no effect if the function is already compiled
        /// ---
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
            stack.push(self.ref.lua, self.ref); // Push function ref
            defer self.state().pop(1); // Remove from stack

            self.state().codegenCompile(-1);
        }

        /// Returns the registry reference ID if valid, otherwise null.
        pub inline fn getRef(self: Function) ?c_int {
            return self.ref.getRef();
        }
    };

    pub inline fn top(self: Self) i32 {
        return self.state.getTop();
    }

    /// Ensures the Lua stack has space for at least `sz` more elements.
    /// ---
    /// This function checks if the stack can grow to accommodate the specified
    /// number of additional elements. Returns an error if the stack cannot be grown.
    /// ---
    /// Used internally by table operations to ensure stack safety before pushing values.
    /// ---
    /// Errors: `Error.OutOfMemory` if stack cannot be grown
    inline fn checkStack(self: Self, sz: i32) !void {
        if (!self.state.checkStack(sz)) {
            return Error.OutOfMemory;
        }
    }

    /// Executes pre-compiled Luau bytecode and returns the result.
    /// ---
    /// Loads the provided bytecode onto the Lua stack and executes it as a function.
    /// The bytecode should be valid Luau bytecode (not LuaJit).
    /// ---
    /// The return type `T` specifies what type to expect from the executed code:
    /// - `void` - Executes code that returns nothing
    /// - `i32`, `f64`, `bool`, etc. - Converts the return value to the specified type
    /// - `?T` - Optional types, returns `null` if conversion fails
    /// - `struct { T1, T2, ... }` - Tuple types for multiple return values
    /// ---
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
    /// ---
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
                            stack.push(self, arg);
                        }
                        break :blk @as(u32, @intCast(info.fields.len));
                    } else {
                        stack.push(self, args);
                        break :blk 1;
                    }
                },
                else => {
                    stack.push(self, args);
                    break :blk 1;
                },
            }
        };

        const ret_count = stack.slotCountFor(R);

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
                    result[field_index] = stack.pop(self, info.fields[field_index].type).?;
                }
                return result;
            }
        }

        return stack.pop(self, R).?;
    }

    /// Compiles and executes Luau source code, returning the result.
    /// ---
    /// Takes Luau source code as a string, compiles it to bytecode using the provided
    /// compilation options, and then executes the resulting bytecode. This is a
    /// convenience function that combines compilation and execution in one step.
    /// ---
    /// The return type `T` specifies what type to expect from the executed code:
    /// - `void` - Executes code that returns nothing
    /// - `i32`, `f64`, `bool`, etc. - Converts the return value to the specified type
    /// - `?T` - Optional types, returns `null` if conversion fails
    /// - `struct { T1, T2, ... }` - Tuple types for multiple return values
    /// ---
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
    /// ---
    /// Parameters:
    /// - `source`: Luau source code to compile and execute
    /// - `opts`: Compilation options (see `Compiler.Opts` for available options)
    /// - `T`: Expected return type
    /// ---
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

    /// Register a user-defined type to be used from Lua.
    /// ---
    /// Takes a Zig struct type and creates Lua bindings for all its methods.
    /// Each public method becomes callable from Lua with automatic type conversion.
    /// The struct must have public methods that follow Lua calling conventions.
    /// ---
    /// Creates a metatable for the type and registers all methods as Lua functions.
    /// Methods are wrapped using the same `createFunc` mechanism as regular Zig functions.
    /// ---
    /// Examples:
    /// ```zig
    /// const Person = struct {
    ///     name: []const u8,
    ///     age: i32,
    ///
    ///     pub fn getName(self: Person) []const u8 {
    ///         return self.name;
    ///     }
    ///
    ///     pub fn getAge(self: Person) i32 {
    ///         return self.age;
    ///     }
    ///
    ///     pub fn setAge(self: *Person, new_age: i32) void {
    ///         self.age = new_age;
    ///     }
    /// };
    ///
    /// lua.registerUserData(Person);
    /// ```
    /// ---
    /// The registered type can then be used from Lua:
    /// ```lua
    /// -- After creating a Person instance in Zig and pushing it to Lua
    /// print(person:getName())  -- Calls Person.getName
    /// print(person:getAge())   -- Calls Person.getAge
    /// person:setAge(30)        -- Calls Person.setAge
    /// ```
    /// ---
    /// Type requirements:
    /// - Must be a struct type
    /// - Must have at least one public method (excluding deinit)
    /// - Methods must be public (pub)
    /// - Methods should follow Lua calling conventions for arguments and return values
    /// ---
    /// NOTE: Each type can only be registered once per Lua state. Attempting to register
    /// the same type twice will panic with a clear error message.
    /// ---
    /// Errors: `Error.OutOfMemory` if memory allocation fails during registration
    pub fn registerUserData(self: Self, comptime T: type) !void {
        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("registerUserData can only be used with struct types, got " ++ @typeName(T));
        }

        const struct_info = type_info.@"struct";
        const type_name: [:0]const u8 = @typeName(T);

        // Count methods (excluding deinit which is handled as destructor)
        comptime var method_count = 0;
        inline for (struct_info.decls) |decl| {
            if (@hasDecl(T, decl.name)) {
                const decl_info = @typeInfo(@TypeOf(@field(T, decl.name)));
                if (decl_info == .@"fn" and !comptime std.mem.eql(u8, decl.name, "deinit")) {
                    method_count += 1;
                }
            }
        }

        // Ensure the type has at least one method to register
        if (comptime method_count == 0) {
            @compileError("Type " ++ @typeName(T) ++ " has no public methods to register as userdata");
        }

        // Number of methods to register + 1 for null terminator
        var methods_buffer: [method_count + 1]State.LuaLReg = undefined;
        var method_index: usize = 0;

        // Add all methods (including init as "new" constructor, excluding deinit)
        inline for (struct_info.decls) |decl| {
            if (@hasDecl(T, decl.name)) {
                const decl_info = @typeInfo(@TypeOf(@field(T, decl.name)));
                if (decl_info == .@"fn" and !comptime std.mem.eql(u8, decl.name, "deinit")) {
                    const method_func = @field(T, decl.name);

                    // Use "new" as the name for init functions, otherwise use the method name
                    const method_name: [:0]const u8 = if (comptime std.mem.eql(u8, decl.name, "init")) "new" else decl.name;

                    methods_buffer[method_index] = State.LuaLReg{
                        .name = method_name.ptr,
                        .func = userdata.createUserDataFunc(T, decl.name, method_func, type_name),
                    };

                    method_index += 1;
                }
            }
        }

        // Null terminate
        methods_buffer[method_index] = State.LuaLReg{ .name = null, .func = null };

        // Create metatable and register methods using dual-purpose approach:
        // 1. Metatable serves as method lookup table for instance methods (via __index)
        // 2. Same metatable is registered globally for static methods and constructor access
        if (!self.state.newMetatable(type_name)) {
            @panic("Type " ++ @typeName(T) ++ " is already registered");
        }

        // Set __index to point to itself
        self.state.pushValue(-1);
        self.state.setField(-2, "__index");

        // Register methods in metatable
        self.state.register(null, methods_buffer[0 .. method_index + 1]);

        // Extract just the type name without module prefix for global registration
        // Example: "myapp.data.User" -> "User", "TestUserData" -> "TestUserData"
        const full_type_name = @typeName(T);
        const type_name_only = if (std.mem.lastIndexOf(u8, full_type_name, ".")) |last_dot|
            full_type_name[last_dot + 1 ..]
        else
            full_type_name;

        // Register the metatable globally so static methods are accessible as TypeName.method()
        self.state.setGlobal(type_name_only);
    }

    /// Dump the current stack contents to a string for debugging
    /// ---
    /// Creates a formatted string representation of all values currently on the Lua stack,
    /// showing their stack indices, types, and string representations. Uses Lua's `toString`
    /// to convert values to strings, showing "nil" for values that cannot be converted.
    /// ---
    /// Format for each stack entry: `  {index} [{type}] {value}`
    /// ---
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
    /// ---
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

// Test functions for function push test
fn testCFunction(state: ?State.LuaState) callconv(.C) c_int {
    _ = state;
    return 0;
}

fn testAdd(a: i32, b: i32) i32 {
    return a + b;
}

test "ref types" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    stack.push(lua, testAdd);
    try expect(lua.state.isFunction(-1));
    try expect(lua.state.isCFunction(-1)); // Zig functions are wrapped as C functions

    const ref = Lua.Ref.init(lua, -1);
    defer ref.deinit();

    try expect(ref.isValid());
    try expect(ref.isFunction());
    try expect(!ref.isTable());

    lua.state.pop(1);
    try expectEq(lua.top(), 0);
}

test "dump stack" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test empty stack
    const empty_dump = try lua.dumpStack(std.testing.allocator);
    defer std.testing.allocator.free(empty_dump);
    try expect(std.mem.indexOf(u8, empty_dump, "Lua stack is empty") != null);

    // Test stack with values
    stack.push(lua, @as(f64, 42.5));
    stack.push(lua, true);
    stack.push(lua, "hello");
    stack.push(lua, @as(?i32, null));

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

test "table ops" {
    const lua = try Lua.init(&std.testing.allocator);
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

    // Test pushing table to stack
    try table.set("test", 42);
    stack.push(lua, table);
    try expectEq(lua.top(), 1);
    try expect(lua.state.isTable(-1));

    // Verify we can access the table value through the pushed table
    stack.push(lua, "test");
    _ = lua.state.getTable(-2);
    try expectEq(stack.pop(lua, i32), 42);

    lua.state.pop(1); // Pop the table
    try expectEq(lua.top(), 0);
}
