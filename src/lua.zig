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

pub const State = @import("State.zig");
pub const Compiler = @import("Compiler.zig");
const Debug = @import("Debug.zig");

const userdata = @import("userdata.zig");
const stack = @import("stack.zig");
const alloc = @import("alloc.zig").alloc;
const assert = @import("assert.zig");

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
        /// Unexpected type on the stack (e.g., attempted to retrieve a function but found a different type).
        InvalidType,
        /// Lua runtime error occurred during function execution.
        Runtime,
        /// Breakpoint could not be set at the specified line.
        InvalidBreakpoint,
    };

    /// Assert handler function type for Luau VM assertions.
    pub const AssertHandler = assert.AssertHandler;

    /// Debug functionality for Lua state
    pub const Debug = @import("Debug.zig");

    /// Garbage collection control for Lua state
    pub const Gc = @import("Gc.zig");

    /// Initialize a new Lua state with optional custom allocator.
    ///
    /// Creates a new Luau virtual machine instance. Pass `null` to use Luau's built-in
    /// default allocator (malloc), or `&allocator` to use a custom Zig allocator. The allocator must
    /// remain valid for the entire lifetime of the Lua state.
    ///
    /// Note: Uses pointer parameter (`?*const Allocator`) due to C interop requirements,
    /// deviating from typical Zig conventions.
    ///
    /// Examples:
    /// ```zig
    /// const lua = try Lua.init(null);                   // Luau default (malloc)
    /// const lua = try Lua.init(&std.testing.allocator); // Custom allocator
    /// defer lua.deinit();
    /// ```
    ///
    /// Returns `Lua` instance or `Error.OutOfMemory` on failure.
    pub fn init(allocator: ?*const Allocator) !Self {
        const result = if (allocator) |alloc_ptr|
            State.initWithAlloc(alloc, @constCast(alloc_ptr))
        else
            State.init();

        const state = result orelse return Error.OutOfMemory;

        return Lua{
            .state = state,
        };
    }

    /// Open all standard Lua libraries.
    pub inline fn openLibs(self: Self) void {
        self.state.openLibs();
    }

    /// Get debug functionality for this Lua state.
    /// Returns a Debug instance that provides debugging operations.
    pub inline fn debug(self: Self) Lua.Debug {
        return Lua.Debug.init(@constCast(&self.state));
    }

    /// Get garbage collector control for this Lua state.
    /// Returns a Gc instance that provides GC operations.
    pub inline fn gc(self: Self) Lua.Gc {
        return Lua.Gc{ .lua = self };
    }

    pub inline fn fromState(state: State.LuaState) Self {
        return Self{
            .state = State{ .lua = state },
        };
    }

    /// Deinitializes the Lua state and releases all associated resources.
    ///
    /// Must be called when the Lua instance is no longer needed to prevent memory leaks.
    ///
    /// NOTE: this should not be called from inside Lua callbacks.
    ///
    /// NOTE: Only call this on the main Lua state, not on threads created with createThread().
    /// Threads are subject to garbage collection and should not be explicitly closed.
    pub fn deinit(self: Lua) void {
        // Only deinit if this is the main thread
        // Threads are garbage collected automatically and should not be closed explicitly
        if (!self.isThread()) {
            self.state.deinit();
        }
        // If this is a thread, do nothing - threads are garbage collected
    }

    /// Get unsafe access to the underlying Lua state.
    ///
    /// Provides direct access to the low-level `State` wrapper for advanced operations
    /// that aren't available through the high-level API. Use with caution as this
    /// bypasses the safety guarantees of the high-level interface.
    ///
    /// This is useful for:
    /// - Direct stack manipulation
    /// - Custom debugging operations
    /// - Advanced VM configuration
    /// - Interfacing with C libraries that expect raw lua_State
    ///
    /// Example:
    /// ```zig
    /// const lua = try Lua.init(null);
    /// defer lua.deinit();
    ///
    /// const state = lua.raw();
    /// state.pushNumber(42);
    /// const value = state.toNumber(-1);
    /// state.pop(1);
    /// ```
    ///
    /// Warning: Operations on the raw state can break assumptions made by the
    /// high-level API and may lead to undefined behavior if not used carefully.
    pub inline fn raw(self: Self) State {
        return self.state;
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

    /// Configure VM event handlers using duck typing.
    ///
    /// Sets callback functions for various VM events. The callbacks object can contain
    /// any combination of the following methods, which will be automatically registered
    /// if present:
    ///
    /// - `interrupt(state: *State, gc: i32) void` - Called at safepoints (loop back edges, call/ret, gc)
    /// - `panic(state: *State, errcode: i32) void` - Called on unprotected errors (if longjmp is used)
    /// - `userthread(parent: ?*State, thread: *State) void` - Called when thread is created/destroyed
    /// - `useratom(s: []const u8) i16` - Called when string is created; returns atom ID
    /// - `debugbreak(debug: *Lua.Debug, ar: Lua.Debug.Info) void` - Called when breakpoint is hit. Note that breakpoints
    ///   set with `breakpoint(line)` in Lua code only trigger this callback - they don't automatically
    ///   interrupt execution. Call `debug.debugBreak()` within this callback to actually interrupt
    ///   execution and return `error.Break` to the caller.
    /// - `debugstep(debug: *Lua.Debug, ar: Lua.Debug.Info) void` - Called after each instruction in single step
    /// - `debuginterrupt(debug: *Lua.Debug, ar: Lua.Debug.Info) void` - Called on thread execution interrupt
    /// - `debugprotectederror(debug: *Lua.Debug) void` - Called when protected call results in error
    /// - `onallocate(state: *State, osize: usize, nsize: usize) void` - Called when a memory operation occurs
    ///   (allocation when osize=0, deallocation when nsize=0, reallocation otherwise).
    ///   Note: This callback is only triggered for Luau's internal allocations, not for all memory operations
    ///
    /// Only methods that exist on the callbacks object will be set. Missing methods are ignored.
    ///
    /// Note: Callbacks are set globally on the Lua state and remain active until the state is destroyed
    /// or new callbacks are set.
    ///
    /// Supports two modes:
    /// 1. Static methods: Pass a struct instance - methods are called as static functions.
    ///    The struct instance is not stored, only the function pointers are registered.
    ///    Methods cannot access instance state and must be stateless.
    ///
    /// 2. Instance methods: Pass a pointer to struct instance - methods are called on the instance.
    ///    The instance pointer is stored in the `userdata` field of the VM callbacks structure.
    ///    Methods receive `self` as the first parameter and can access/modify instance state.
    ///
    ///    IMPORTANT: The user is responsible for keeping the instance alive for the entire
    ///    lifetime of the Lua state. If the instance is destroyed while callbacks are still
    ///    registered, calling the callbacks will result in undefined behavior (likely a crash).
    ///    The pointer must remain valid until the Lua state is destroyed or new callbacks are set.
    ///
    /// Examples:
    /// ```zig
    /// // Static methods
    /// const MyCallbacks = struct {
    ///     fn interrupt(state: *State, gc: i32) void {
    ///         std.debug.print("VM interrupt: gc={}\n", .{gc});
    ///     }
    /// };
    /// lua.setCallbacks(MyCallbacks{});
    ///
    /// // Instance methods
    /// const MyCallbacks = struct {
    ///     counter: u32 = 0,
    ///     fn interrupt(self: *@This(), state: *State, gc: i32) void {
    ///         self.counter += 1;
    ///         std.debug.print("VM interrupt #{}: gc={}\n", .{self.counter, gc});
    ///     }
    /// };
    /// var callbacks = MyCallbacks{};
    /// lua.setCallbacks(&callbacks);
    /// ```
    pub fn setCallbacks(self: Self, callbacks: anytype) void {
        const cb = self.state.callbacks();

        const type_info = @typeInfo(@TypeOf(callbacks));

        // Handle both struct instances and pointers to struct instances
        const is_instance = type_info == .pointer;
        const CallbackType = if (is_instance) type_info.pointer.child else @TypeOf(callbacks);
        const callback_type_info = @typeInfo(CallbackType);

        if (callback_type_info != .@"struct") return;

        // Store instance pointer in userdata if it's a pointer
        if (is_instance) {
            cb.userdata = @ptrCast(@constCast(callbacks));
        } else {
            cb.userdata = null;
        }

        if (@hasDecl(CallbackType, "interrupt")) {
            cb.interrupt = struct {
                fn wrapper(L: ?State.LuaState, gc_flag: c_int) callconv(.C) void {
                    var state = State{ .lua = L.? };

                    if (comptime is_instance) {
                        const callbacks_struct = state.callbacks();
                        const instance: *CallbackType = @ptrCast(@alignCast(callbacks_struct.userdata.?));
                        instance.interrupt(&state, @intCast(gc_flag));
                    } else {
                        CallbackType.interrupt(&state, @intCast(gc_flag));
                    }
                }
            }.wrapper;
        }

        if (@hasDecl(CallbackType, "panic")) {
            cb.panic = struct {
                fn wrapper(L: ?State.LuaState, errcode: c_int) callconv(.C) void {
                    var state = State{ .lua = L.? };

                    if (comptime is_instance) {
                        const callbacks_struct = state.callbacks();
                        const instance: *CallbackType = @ptrCast(@alignCast(callbacks_struct.userdata.?));
                        instance.panic(&state, @intCast(errcode));
                    } else {
                        CallbackType.panic(&state, @intCast(errcode));
                    }
                }
            }.wrapper;
        }

        if (@hasDecl(CallbackType, "userthread")) {
            cb.userthread = struct {
                fn wrapper(LP: ?State.LuaState, L: ?State.LuaState) callconv(.C) void {
                    var parent_state: ?State = if (LP) |p| State{ .lua = p } else null;
                    var thread_state = State{ .lua = L.? }; // L is never null in practice

                    if (comptime is_instance) {
                        const callbacks_struct = thread_state.callbacks();
                        const instance: *CallbackType = @ptrCast(@alignCast(callbacks_struct.userdata.?));
                        instance.userthread(if (parent_state) |*ps| ps else null, &thread_state);
                    } else {
                        CallbackType.userthread(if (parent_state) |*ps| ps else null, &thread_state);
                    }
                }
            }.wrapper;
        }

        if (@hasDecl(CallbackType, "useratom")) {
            cb.useratom = struct {
                fn wrapper(s: [*c]const u8, l: usize) callconv(.C) i16 {
                    const slice = s[0..l];

                    if (comptime is_instance) {
                        // Note: useratom doesn't receive a Lua state, so we can't access userdata directly.
                        // This callback must remain static for now due to C API limitations.
                        @compileError("useratom callback cannot be used with instance methods as it doesn't receive a Lua state parameter");
                    } else {
                        return CallbackType.useratom(slice);
                    }
                }
            }.wrapper;
        }

        if (@hasDecl(CallbackType, "debugbreak")) {
            cb.debugbreak = struct {
                fn wrapper(L: ?State.LuaState, ar: ?*State.Debug) callconv(.C) void {
                    var lua = Lua.fromState(L.?);
                    var debug_instance = lua.debug();
                    const debug_info = Lua.Debug.Info.fromC(ar.?);

                    if (comptime is_instance) {
                        const callbacks_struct = lua.state.callbacks();
                        const instance: *CallbackType = @ptrCast(@alignCast(callbacks_struct.userdata.?));
                        instance.debugbreak(&debug_instance, debug_info);
                    } else {
                        CallbackType.debugbreak(&debug_instance, debug_info);
                    }
                }
            }.wrapper;
        }

        if (@hasDecl(CallbackType, "debugstep")) {
            cb.debugstep = struct {
                fn wrapper(L: ?State.LuaState, ar: ?*State.Debug) callconv(.C) void {
                    var lua = Lua.fromState(L.?);
                    var debug_instance = lua.debug();
                    const debug_info = Lua.Debug.Info.fromC(ar.?);

                    if (comptime is_instance) {
                        const callbacks_struct = lua.state.callbacks();
                        const instance: *CallbackType = @ptrCast(@alignCast(callbacks_struct.userdata.?));
                        instance.debugstep(&debug_instance, debug_info);
                    } else {
                        CallbackType.debugstep(&debug_instance, debug_info);
                    }
                }
            }.wrapper;
        }

        if (@hasDecl(CallbackType, "debuginterrupt")) {
            cb.debuginterrupt = struct {
                fn wrapper(L: ?State.LuaState, ar: ?*State.Debug) callconv(.C) void {
                    var lua = Lua.fromState(L.?);
                    var debug_instance = lua.debug();
                    const debug_info = Lua.Debug.Info.fromC(ar.?);

                    if (comptime is_instance) {
                        const callbacks_struct = lua.state.callbacks();
                        const instance: *CallbackType = @ptrCast(@alignCast(callbacks_struct.userdata.?));
                        instance.debuginterrupt(&debug_instance, debug_info);
                    } else {
                        CallbackType.debuginterrupt(&debug_instance, debug_info);
                    }
                }
            }.wrapper;
        }

        if (@hasDecl(CallbackType, "debugprotectederror")) {
            cb.debugprotectederror = struct {
                fn wrapper(L: ?State.LuaState) callconv(.C) void {
                    var lua = Lua.fromState(L.?);
                    var debug_instance = lua.debug();

                    if (comptime is_instance) {
                        const callbacks_struct = lua.state.callbacks();
                        const instance: *CallbackType = @ptrCast(@alignCast(callbacks_struct.userdata.?));
                        instance.debugprotectederror(&debug_instance);
                    } else {
                        CallbackType.debugprotectederror(&debug_instance);
                    }
                }
            }.wrapper;
        }

        if (@hasDecl(CallbackType, "onallocate")) {
            cb.onallocate = struct {
                fn wrapper(L: ?State.LuaState, osize: usize, nsize: usize) callconv(.C) void {
                    if (L) |lua_state| {
                        var state = State{ .lua = lua_state };

                        if (comptime is_instance) {
                            const callbacks_struct = state.callbacks();
                            const instance: *CallbackType = @ptrCast(@alignCast(callbacks_struct.userdata.?));
                            instance.onallocate(&state, osize, nsize);
                        } else {
                            CallbackType.onallocate(&state, osize, nsize);
                        }
                    }
                }
            }.wrapper;
        }
    }

    /// A reference to a Lua value.
    ///
    /// Holds a reference ID that can be used to retrieve the value later.
    /// Must be explicitly released using deinit() to avoid memory leaks.
    pub const Ref = struct {
        lua: Lua,
        ref: c_int,

        /// Creates a reference to a value on the stack.
        ///
        /// Does not consume the value.
        pub inline fn init(lua: Lua, index: i32) Ref {
            return Ref{
                .lua = lua,
                .ref = lua.state.ref(index),
            };
        }

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
        pub inline fn getRef(self: Ref) ?c_int {
            return if (self.isValid()) self.ref else null;
        }
    };

    /// High-level table wrapper providing type-safe access to Lua tables.
    ///
    /// Tables are Lua's primary data structure, serving as arrays, dictionaries, objects,
    /// and namespaces. This wrapper provides idiomatic Zig access to Lua tables with
    /// automatic type conversion and memory management.
    ///
    /// Key features:
    /// - Type-safe get/set operations with automatic Zig <-> Lua type conversion
    /// - Raw access methods that bypass Lua metamethods for performance
    /// - Function calling support for tables containing functions
    /// - Iteration support with automatic resource management
    /// - Length operations following Lua semantics
    ///
    /// Memory management:
    /// Tables hold a reference in the Lua registry and must be explicitly released
    /// using `deinit()` to avoid memory leaks. The only exception is the globals
    /// table from `lua.globals()`, which uses a pseudo-index and doesn't require
    /// explicit cleanup (though calling `deinit()` on it is safe).
    ///
    /// Examples:
    /// ```zig
    /// const table = lua.createTable(.{ .rec = 10 });
    /// defer table.deinit();
    ///
    /// // Set and get values with automatic type conversion
    /// try table.set("name", "example");
    /// const name = try table.get("name", []const u8);
    ///
    /// // Use raw access to bypass metamethods
    /// try table.setRaw(1, 42);
    /// const value = try table.getRaw(1, i32);
    ///
    /// // Call functions stored in tables
    /// const result = try table.call("process", .{10, 20}, i32);
    /// ```
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

            stack.push(self.ref.lua, self.ref); // Push table ref
            stack.push(self.ref.lua, value); // Push value
            self.state().rawSetI(-2, index); // Set table and pop value
            self.state().pop(1); // Pop table
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

            stack.push(self.ref.lua, self.ref); // Push table ref
            _ = self.state().rawGetI(-1, index); // Push value of t[i] onto stack.

            defer self.state().pop(1); // Pop table

            return stack.pop(self.ref.lua, T);
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
        /// const inner = lua.createTable(.{ .rec = 2 });
        /// defer inner.deinit();
        /// try inner.set("x", 5);
        /// try table.set("inner", inner);          // Store table in table
        /// ```
        ///
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn set(self: Table, key: anytype, value: anytype) !void {
            try self.ref.lua.checkStack(3);

            stack.push(self.ref.lua, self.ref); // Push table ref
            stack.push(self.ref.lua, key); // Push key
            stack.push(self.ref.lua, value); // Push value

            self.state().setTable(-3); // Set table[key] = value and pop key and value
            self.state().pop(1); // Pop table
        }

        /// Sets a function with upvalues in the table as a Lua C closure.
        ///
        /// Similar to `set(key, func)` but allows creating closures with captured values.
        /// Upvalues are values that are captured and accessible to the function.
        /// The function must accept upvalues as its first parameter using the `Upvalues(T)` wrapper type.
        ///
        /// WARNING: When using light user data pointers as upvalues, the user is responsible
        /// for ensuring the pointer remains valid for the lifetime of the closure.
        ///
        /// Parameters:
        /// - `key`: The table key where the closure will be stored
        /// - `upvalues`: Values to be captured as upvalues (single value or tuple)
        /// - `func`: A Zig function with `Upvalues(T)` as its first parameter
        ///
        /// Examples:
        /// ```zig
        /// fn add(upv: Upvalues(i32), x: i32) i32 {
        ///     return upv.value + x;
        /// }
        /// try table.setClosure("add5", 5, add);
        ///
        /// fn transform(upv: Upvalues(struct { scale: f32, offset: f32 }), x: f32) f32 {
        ///     return x * upv.value.scale + upv.value.offset;
        /// }
        /// try table.setClosure("scale2add10", .{ .scale = 2.0, .offset = 10.0 }, transform);
        /// ```
        ///
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn setClosure(self: Table, key: anytype, upvalues: anytype, func: anytype) !void {
            const FuncType = @TypeOf(func);
            const func_info = @typeInfo(FuncType);

            if (func_info != .@"fn") {
                @compileError("Third parameter must be a function");
            }

            const arg_tuple = std.meta.ArgsTuple(FuncType);
            const arg_fields = std.meta.fields(arg_tuple);

            if (arg_fields.len == 0) {
                @compileError("Function must have at least one parameter (Upvalues)");
            }

            const FirstParamType = arg_fields[0].type;
            const first_param_info = @typeInfo(FirstParamType);

            if (first_param_info != .@"struct" or
                !@hasDecl(FirstParamType, "is_upvalues") or
                !FirstParamType.is_upvalues)
            {
                @compileError("First parameter of the function must be an Upvalues type");
            }

            const upvalues_info = @typeInfo(@TypeOf(upvalues));
            const upvalue_count = if (upvalues_info == .@"struct" and upvalues_info.@"struct".is_tuple)
                upvalues_info.@"struct".fields.len
            else
                1;

            try self.ref.lua.checkStack(@intCast(3 + upvalue_count));

            stack.push(self.ref.lua, self.ref); // Push table ref
            stack.push(self.ref.lua, key); // Push key

            // Push upvalues onto the stack
            if (upvalues_info == .@"struct" and upvalues_info.@"struct".is_tuple) {
                inline for (0..upvalues_info.@"struct".fields.len) |i| {
                    stack.push(self.ref.lua, upvalues[i]);
                }
            } else {
                stack.push(self.ref.lua, upvalues);
            }

            // Create the closure with upvalues
            const trampoline: State.CFunction = stack.createFunc(self.ref.lua, func);
            self.state().pushCClosureK(trampoline, @typeName(@TypeOf(func)), @intCast(upvalue_count), null);

            self.state().setTable(-3); // Set table[key] = closure and pop key and value
            self.state().pop(1); // Pop table
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

            stack.push(self.ref.lua, self.ref); // Push table ref
            stack.push(self.ref.lua, key); // Push key

            _ = self.state().getTable(-2); // Pop key and push "table[key]" onto stack
            defer self.state().pop(1); // Pop table

            return stack.pop(self.ref.lua, T);
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
        /// Errors: `Error.OutOfMemory` if stack allocation fails, `Error.Runtime` if function execution fails
        pub fn call(self: Table, key: anytype, args: anytype, comptime R: type) !Result(R) {
            try self.ref.lua.checkStack(3);

            stack.push(self.ref.lua, self.ref); // Push table ref
            stack.push(self.ref.lua, key); // Push key
            _ = self.state().getTable(-2); // Get function from table, pop key

            defer self.state().pop(-1); // Pop table in the end.

            return self.ref.lua.call(args, R, false);
        }

        /// Compile a function stored in this table using Luau's JIT code generator for improved performance.
        ///
        /// This method retrieves a function from the table by name and compiles it (along with any
        /// nested functions it contains) to native machine code using Luau's code generator.
        /// Compiled functions execute significantly faster than interpreted bytecode.
        ///
        /// Prerequisites:
        /// - `enable_codegen()` must be called successfully first
        /// - The named field must contain a function
        ///
        /// Notes:
        /// - This is a one-time operation - functions remain compiled for their lifetime
        /// - Compilation happens immediately and synchronously
        /// - Nested functions within the target function are also compiled
        /// - Has no effect if the function is already compiled
        ///
        /// Example:
        /// ```zig
        /// if (lua.enable_codegen()) {
        ///     _ = try lua.eval("function square(x) return x * x end", .{}, void);
        ///     const globals = lua.globals();
        ///     try globals.compile("square");
        ///
        ///     // Call twice to ensure compilation doesn't break subsequent calls
        ///     const result1 = try lua.eval("return square(5)", .{}, i32);   // 25
        ///     const result2 = try lua.eval("return square(10)", .{}, i32);  // 100
        /// }
        /// ```
        ///
        /// Errors: `Error.InvalidType` if the named field is not a function
        pub fn compile(self: Table, name: []const u8) !void {
            stack.push(self.ref.lua, self.ref); // Push table ref
            stack.push(self.ref.lua, name); // Push func name
            _ = self.state().getTable(-2); // Get function from table, pop key

            if (!self.state().isFunction(-1)) {
                return Error.InvalidType;
            }

            self.state().codegenCompile(-1);
            self.state().pop(1); // Pop function
        }

        /// Returns the registry reference ID if valid, otherwise null.
        pub inline fn getRef(self: Table) ?c_int {
            return self.ref.getRef();
        }

        /// Returns the length of the table.
        ///
        /// This method returns the table length as defined by the Lua length operator (#).
        /// For arrays (tables with consecutive integer keys starting from 1), this returns
        /// the number of elements. For hash tables or tables with holes, the behavior
        /// follows Lua's length semantics.
        ///
        /// If the table has a `__len` metamethod, it will be invoked to determine the length.
        /// Otherwise, the raw table length is returned.
        ///
        /// Examples:
        /// ```zig
        /// const table = lua.createTable(.{});
        /// defer table.deinit();
        ///
        /// // Empty table
        /// try expectEq(try table.len(), 0);
        ///
        /// // Array-like table
        /// try table.setRaw(1, "first");
        /// try table.setRaw(2, "second");
        /// try table.setRaw(3, "third");
        /// try expectEq(try table.len(), 3);
        ///
        /// // Hash table (length may be 0 or undefined)
        /// try table.set("key", "value");
        /// const hash_len = try table.len(); // Implementation dependent
        /// ```
        ///
        /// Returns: `i32` - The length of the table
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn len(self: Table) !i32 {
            try self.ref.lua.checkStack(1);

            stack.push(self.ref.lua, self.ref); // Push table ref
            defer self.state().pop(1); // Pop table

            return self.state().objLen(-1);
        }

        /// Creates an iterator for this table.
        ///
        /// The returned iterator automatically handles all resource management
        /// for safe iteration over table entries.
        ///
        /// Examples:
        /// ```zig
        /// const table = lua.createTable(.{});
        /// defer table.deinit();
        ///
        /// try table.set("name", "Alice");
        /// try table.set(1, "first");
        ///
        /// var iterator = table.iterator();
        /// while (try iterator.next()) |entry| {
        ///     if (entry.key.asString()) |s| {
        ///         std.debug.print("String key: {s}\n", .{s});
        ///     }
        /// }
        /// ```
        ///
        /// Returns: `Iterator` - A new iterator instance ready for use
        pub fn iterator(self: Table) Iterator {
            return Iterator{
                .table = self,
                .current_entry = null,
            };
        }

        /// Set the readonly state of this table.
        ///
        /// When a table is set to readonly, attempting to modify it will fail.
        /// This is useful for protecting tables from accidental or malicious modification.
        ///
        /// Examples:
        /// ```zig
        /// const table = lua.createTable(.{});
        /// defer table.deinit();
        ///
        /// try table.set("key", "value");
        /// table.setReadonly(true); // Make table read-only
        ///
        /// // This would now fail:
        /// // table.set("new_key", "new_value");
        /// ```
        ///
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn setReadonly(self: Table, readonly: bool) !void {
            try self.ref.lua.checkStack(1);

            stack.push(self.ref.lua, self.ref); // Push table ref
            defer self.state().pop(1); // Pop table

            self.state().setReadonly(-1, readonly);
        }

        /// Check if this table is readonly.
        ///
        /// Returns `true` if the table is read-only, `false` if it can be modified.
        ///
        /// Examples:
        /// ```zig
        /// const table = lua.createTable(.{});
        /// defer table.deinit();
        ///
        /// try expect(!try table.isReadonly()); // Initially writable
        /// try table.setReadonly(true);
        /// try expect(try table.isReadonly());  // Now readonly
        /// ```
        ///
        /// Returns: `true` if table is readonly, `false` otherwise
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn isReadonly(self: Table) !bool {
            try self.ref.lua.checkStack(1);

            stack.push(self.ref.lua, self.ref); // Push table ref
            defer self.state().pop(1); // Pop table

            return self.state().getReadonly(-1);
        }

        /// Set the safe environment flag for this table.
        ///
        /// Controls import optimization behavior in the Luau VM when this table is used as an environment:
        ///
        /// **When `safeenv = true` (default for sandboxed environments):**
        /// - Enables fast-path import resolution for better performance
        /// - VM can use optimized built-in function calls and iterator operations
        /// - Assumes the environment is immutable and hasn't been monkey-patched
        /// - Used by sandboxing system to mark secure, read-only environments
        ///
        /// **When `safeenv = false`:**
        /// - Disables import optimization for more flexible global access
        /// - VM uses slower but more defensive code paths
        /// - Required when environment may be modified at runtime
        /// - Automatically set by operations like `getfenv()`/`setfenv()`
        ///
        /// This is a VM-level performance optimization flag. Setting it incorrectly may cause
        /// unexpected behavior if the environment safety assumptions don't match actual usage.
        ///
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn setSafeEnv(self: Table, safe: bool) !void {
            try self.ref.lua.checkStack(1);

            stack.push(self.ref.lua, self.ref); // Push table ref
            defer self.state().pop(1); // Pop table

            self.state().setSafeEnv(-1, safe);
        }

        /// Set the metatable for this table.
        ///
        /// Associates a metatable with this table, enabling custom behavior through metamethods.
        /// The metatable can define special functions like `__index`, `__newindex`, `__len`, etc.
        /// that will be called when performing operations on the table.
        ///
        /// Examples:
        /// ```zig
        /// const table = lua.createTable(.{});
        /// defer table.deinit();
        ///
        /// const metatable = lua.createTable(.{});
        /// defer metatable.deinit();
        ///
        /// // Add metamethods to the metatable
        /// try metatable.set("__index", custom_index_func);
        /// try metatable.set("__len", custom_len_func);
        ///
        /// // Apply metatable to table
        /// try table.setMetaTable(metatable);
        /// ```
        ///
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn setMetaTable(self: Table, metatable: Table) !void {
            try self.ref.lua.checkStack(2);

            stack.push(self.ref.lua, self.ref); // Push table ref
            stack.push(self.ref.lua, metatable.ref); // Push metatable ref

            _ = self.state().setMetatable(-2); // Set metatable and pop it
            self.state().pop(1); // Pop table
        }

        /// Get the metatable for this table.
        ///
        /// Retrieves the metatable associated with this table, if any. Returns `null`
        /// if the table has no metatable. The returned metatable can be inspected
        /// or modified to change the table's behavior.
        ///
        /// Examples:
        /// ```zig
        /// const table = lua.createTable(.{});
        /// defer table.deinit();
        ///
        /// // Initially no metatable
        /// const maybe_metatable = try table.getMetaTable();
        /// try expect(maybe_metatable == null);
        ///
        /// // After setting a metatable
        /// const metatable = lua.createTable(.{});
        /// defer metatable.deinit();
        /// try table.setMetaTable(metatable);
        ///
        /// const retrieved_metatable = try table.getMetaTable();
        /// defer if (retrieved_metatable) |mt| mt.deinit();
        /// try expect(retrieved_metatable != null);
        /// ```
        ///
        /// Returns: `?Table` - The metatable if present, `null` if no metatable
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn getMetaTable(self: Table) !?Table {
            try self.ref.lua.checkStack(1);

            stack.push(self.ref.lua, self.ref); // Push table ref
            defer self.state().pop(1); // Pop table

            if (self.state().getMetatable(-1)) {
                // Metatable is now on top of the stack, create a reference to it
                const metatable_ref = Ref.init(self.ref.lua, -1);
                self.state().pop(1); // Remove metatable from stack
                return Table{ .ref = metatable_ref };
            } else {
                // No metatable
                return null;
            }
        }

        /// Clears all entries from the table.
        ///
        /// Removes all key-value pairs from the table, resetting it to an empty state.
        /// The table's metatable (if any) is preserved. This operation affects both
        /// the array part and hash part of the table.
        ///
        /// If the table is readonly, this operation will trigger a Lua error at runtime.
        /// Readonly tables cannot be modified, including clearing their contents.
        ///
        /// Examples:
        /// ```zig
        /// const table = lua.createTable(.{});
        /// defer table.deinit();
        ///
        /// // Add some entries
        /// try table.set("name", "Alice");
        /// try table.set(1, 42);
        /// try table.set("data", true);
        ///
        /// // Clear all entries
        /// try table.clear();
        ///
        /// // Table is now empty
        /// const name = try table.get("name", []const u8);
        /// try expect(name == null);
        /// ```
        ///
        /// Note: Attempting to clear a readonly table will result in a runtime error
        /// from the Lua VM rather than returning an error through Zig's error system.
        ///
        /// Errors: `Error.OutOfMemory` if stack allocation fails
        pub fn clear(self: Table) !void {
            try self.ref.lua.checkStack(1);

            stack.push(self.ref.lua, self.ref); // Push table ref
            self.state().clearTable(-1); // Clear table
            self.state().pop(1); // Pop table
        }

        /// Creates a shallow copy of the table.
        ///
        /// Returns a new table with the same key-value pairs as the original.
        /// This is a shallow copy: primitive values (numbers, strings, booleans) are
        /// duplicated, but reference types (tables, functions, userdata) are shared
        /// between the original and cloned table.
        ///
        /// The clone inherits the original table's metatable reference (not cloned).
        /// The readonly and safeenv flags are not copied to the clone.
        ///
        /// Examples:
        /// ```zig
        /// const original = lua.createTable(.{});
        /// defer original.deinit();
        /// try original.set("name", "Alice");
        ///
        /// const cloned = try original.clone();
        /// defer cloned.deinit();
        ///
        /// // Clone has same values
        /// const name = try cloned.get("name", []const u8);
        /// try expect(std.mem.eql(u8, name.?, "Alice"));
        /// ```
        ///
        /// Returns: `Table` - A new table containing a shallow copy of the original
        /// Errors: `Error.OutOfMemory` if allocation fails
        pub fn clone(self: Table) !Table {
            try self.ref.lua.checkStack(2);

            stack.push(self.ref.lua, self.ref); // Push table ref
            self.state().cloneTable(-1); // Clone table, pushes clone on stack

            // Create a reference to the cloned table on the stack
            const cloned_ref = Ref.init(self.ref.lua, -1);
            self.state().pop(2); // Pop both original and cloned tables

            return Table{ .ref = cloned_ref };
        }

        /// Entry representing a key-value pair from table iteration.
        /// Resources are automatically managed when using the `Iterator` type.
        pub const Entry = struct {
            key: Lua.Value,
            value: Lua.Value,

            /// Releases the resources held by this entry.
            /// Note: This is automatically called by the Iterator.
            pub fn deinit(self: Entry) void {
                self.key.deinit();
                self.value.deinit();
            }
        };

        /// Iterator for table entries.
        ///
        /// The iterator handles all entry cleanup automatically.
        ///
        /// Examples:
        /// ```zig
        /// const table = lua.createTable(.{});
        /// defer table.deinit();
        ///
        /// try table.set("name", "Alice");
        /// try table.set(1, "first");
        ///
        /// var iterator = table.iterator();
        /// while (try iterator.next()) |entry| {
        ///     if (entry.key.asString()) |s| {
        ///         std.debug.print("String key: {s}\n", .{s});
        ///     }
        /// }
        /// ```
        pub const Iterator = struct {
            table: Table,
            current_entry: ?Entry,

            /// Advances the iterator and returns the next entry, or null if done.
            /// Automatically manages cleanup of previous entries.
            ///
            /// Returns: `?*const Entry` - Pointer to the next entry, or null if iteration complete
            /// Errors: `Error.OutOfMemory` if stack allocation fails
            pub fn next(self: *Iterator) !?*const Entry {
                try self.table.ref.lua.checkStack(3);

                // Push table onto stack
                stack.push(self.table.ref.lua, self.table.ref);
                defer self.table.state().pop(1);

                // Push key for lua_next (nil if null)
                if (self.current_entry) |entry| {
                    stack.push(self.table.ref.lua, entry.key);
                    entry.deinit();
                } else {
                    self.table.state().pushNil();
                }

                // Call lua_next: pops key, pushes next key-value pair (or nothing if done)
                if (self.table.state().next(-2)) {
                    // Stack now has: table, key, value

                    // Pop value and key
                    const value = stack.pop(self.table.ref.lua, Lua.Value).?;
                    const key = stack.pop(self.table.ref.lua, Lua.Value).?;

                    self.current_entry = Entry{ .key = key, .value = value };
                    return &self.current_entry.?;
                } else {
                    // No more entries
                    self.current_entry = null;
                    return null;
                }
            }
        };
    };

    /// Generic Lua value that can represent any runtime Lua type.
    ///
    /// This union provides a way to work with Lua values when their types are not known at compile time.
    /// It's particularly useful when implementing metamethods like `__index` where the return type depends
    /// on runtime conditions, or when handling values returned from Lua code where the type varies.
    ///
    /// The Value type integrates seamlessly with Lua's type system through automatic conversions in
    /// table operations, function calls, and other high-level APIs.
    ///
    /// Examples:
    /// ```zig
    /// // Creating values directly
    /// const num_val = Lua.Value{ .number = 42.0 };
    /// const str_val = Lua.Value{ .string = "hello" };
    /// const nil_val = Lua.Value.nil;
    ///
    /// // Using with table operations
    /// const table = lua.createTable(.{});
    /// defer table.deinit();
    /// try table.set("dynamic", num_val);  // Automatically pushes Value to Lua
    /// const value = try table.get("dynamic", Lua.Value);  // Gets Value from table
    ///
    /// // Useful for metamethod implementations
    /// fn indexMetamethod(self: *MyTable, key: []const u8) Lua.Value {
    ///     if (std.mem.eql(u8, key, "count")) {
    ///         return Lua.Value{ .number = @floatFromInt(self.items.len) };
    ///     } else if (std.mem.eql(u8, key, "name")) {
    ///         return Lua.Value{ .string = self.name };
    ///     }
    ///     return Lua.Value.nil;
    /// }
    ///
    /// // Working with values from Lua
    /// const result = try lua.eval("return type({})", .{}, Lua.Value);
    /// switch (result) {
    ///     .string => |s| std.debug.print("Type: {s}\n", .{s}),
    ///     else => {},
    /// }
    /// ```
    pub const Value = union(enum) {
        nil,
        boolean: bool,
        number: f64,
        string: []const u8,
        table: Table,
        function: Function,
        userdata: Ref,
        lightuserdata: *anyopaque,

        /// Releases any resources held by this Value.
        ///
        /// For reference types (tables, functions), this releases the Lua reference.
        /// For other types, this is a no-op. It's safe to call deinit multiple times
        /// or on non-reference types.
        ///
        /// Examples:
        /// ```zig
        /// const value = stack.pop(lua, Value);
        /// defer if (value) |v| v.deinit();
        /// ```
        pub fn deinit(self: Value) void {
            switch (self) {
                .table => |t| t.deinit(),
                .function => |f| f.deinit(),
                .userdata => |u| u.deinit(),
                else => {}, // No cleanup needed for primitive types
            }
        }

        /// Returns the string value if this Value contains a string, otherwise null.
        pub fn asString(self: Value) ?[]const u8 {
            return switch (self) {
                .string => |s| s,
                else => null,
            };
        }

        /// Returns the number value if this Value contains a number, otherwise null.
        pub fn asNumber(self: Value) ?f64 {
            return switch (self) {
                .number => |n| n,
                else => null,
            };
        }

        /// Returns the integer value if this Value contains a number, otherwise null.
        /// The number is cast to i32.
        pub fn asInt(self: Value) ?i32 {
            return switch (self) {
                .number => |n| @intFromFloat(n),
                else => null,
            };
        }
    };

    /// Generic wrapper for upvalues passed to Lua C closure functions.
    ///
    /// This type enables functions to receive upvalues in a type-safe manner when registered
    /// as Lua C closures with `table.setClosure()`. The upvalues are automatically injected
    /// when the function is called from Lua.
    ///
    /// `Upvalues(T)` must be used as the first parameter of the function.
    ///
    /// See `Table.setClosure()` documentation for usage examples.
    pub fn Upvalues(comptime T: type) type {
        return struct {
            value: T,

            /// Marker field to distinguish from regular types
            pub const is_upvalues = true;
            pub const UpvalueType = T;
        };
    }

    /// Variadic arguments iterator for functions accepting variable number of arguments from Lua.
    ///
    /// This type enables Zig functions to accept any number of arguments from Lua
    /// without allocating memory. It provides an iterator interface to access remaining
    /// stack arguments. Varargs must always be the last parameter in a function signature.
    ///
    /// Example:
    /// ```zig
    /// fn sum(initial: f64, args: Varargs) f64 {
    ///     var total = initial;
    ///     var iter = args;
    ///     while (iter.next(f64)) |n| {
    ///         total += n;
    ///     }
    ///     return total;
    /// }
    /// ```
    ///
    /// The iterator does not allocate memory and directly accesses values from the Lua stack.
    pub const Varargs = struct {
        lua: Lua,
        base: i32,
        index: i32,
        count: i32,

        /// Marker field to distinguish from regular types
        pub const is_varargs = true;

        /// Get the number of variadic arguments
        pub fn len(self: Varargs) usize {
            return @intCast(self.count);
        }

        /// Check if any variadic arguments were provided
        pub fn isEmpty(self: Varargs) bool {
            return self.count == 0;
        }

        /// Get the next value from varargs, returns null when done
        pub fn next(self: *Varargs, comptime T: type) ?T {
            const offset = self.index - self.base;
            if (offset >= self.count) return null;

            const result = self.at(T, @intCast(offset));
            self.index += 1;
            return result;
        }

        /// Get value at specific index (0-based)
        pub fn at(self: Varargs, comptime T: type, index: usize) ?T {
            if (index >= self.len()) return null;

            const stack_index = self.base + @as(i32, @intCast(index));

            return stack.checkArg(self.lua, stack_index, T);
        }

        /// Get the Lua type of value at specific index (0-based)
        pub fn typeAt(self: Varargs, index: usize) ?State.Type {
            if (index >= self.len()) return null;

            const stack_index = self.base + @as(i32, @intCast(index));
            return self.lua.state.getType(stack_index);
        }

        /// Reset iterator to beginning
        pub fn reset(self: *Varargs) void {
            self.index = self.base;
        }

        /// Throw an error with custom message for the current iterator position
        pub fn raiseError(self: Varargs, message: [:0]const u8) noreturn {
            const arg_index = (self.index - self.base) + 1; // Convert to 1-based argument numbering
            self.lua.state.argError(@intCast(arg_index), message);
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

        return Table{ .ref = Ref.init(self, -1) };
    }

    /// Creates a new thread (coroutine) in the Lua state.
    ///
    /// Creates an independent execution context that shares the global environment
    /// with the original thread but has its own execution stack. The thread can be
    /// used to run Lua functions as coroutines.
    ///
    /// The returned Thread must be explicitly released using `deinit()` to free the reference.
    /// The underlying Lua thread is subject to garbage collection.
    ///
    /// Examples:
    /// ```zig
    /// // Create a new thread
    /// const thread = lua.createThread();
    /// defer thread.deinit();
    ///
    /// // Load a function into the thread
    /// _ = try lua.eval(
    ///     \\function counter(start)
    ///     \\    local i = start
    ///     \\    while true do
    ///     \\        coroutine.yield(i)
    ///     \\        i = i + 1
    ///     \\    end
    ///     \\end
    /// , .{}, void);
    ///
    /// // Get the function and push it to the thread
    /// const globals = lua.globals();
    /// const counter_fn = try globals.get("counter", Lua.Function);
    /// defer counter_fn.?.deinit();
    ///
    /// // Resume the coroutine with initial value
    /// const res1 = try thread.resume_(.{10}, i32);
    /// std.debug.print("First: {}\n", .{res1.result}); // Prints: First: 10
    ///
    /// // Resume again to get next value
    /// const res2 = try thread.resume_(.{}, i32);
    /// std.debug.print("Second: {}\n", .{res2.result}); // Prints: Second: 11
    /// ```
    ///
    /// Returns: `Thread` - A wrapper around the newly created Lua thread
    /// Creates a new thread (coroutine) and returns a Lua object for it.
    /// The returned Lua object can be used to call functions and resume coroutines.
    pub inline fn createThread(self: Self) Self {
        const thread_state = self.state.newThread();
        return Self.fromState(thread_state.lua);
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

        /// Returns the underlying Lua state for direct state operations.
        inline fn state(self: Function) State {
            return self.ref.lua.state;
        }

        pub fn deinit(self: Function) void {
            self.ref.deinit();
        }

        /// Calls the function with the provided arguments and returns the result.
        ///
        /// Pushes the function onto the stack, followed by the arguments, then calls the function
        /// and returns the result converted to the specified type.
        ///
        /// NOTE: When called on a function in a thread (created with
        /// `createThread()`), this method automatically uses resume semantics, allowing the
        /// function to yield. In the main state, it uses regular call semantics.
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
        ///
        /// // Coroutine example - function can yield
        /// const thread = lua.createThread();
        /// const func = try thread.globals().get("coroutine_func", Function).?;
        /// defer func.deinit();
        ///
        /// const result1 = try func.call(.{}, i32);     // Start coroutine, may yield
        /// const result2 = try func.call(.{5}, i32);    // Continue coroutine with arg 5
        /// const result3 = try func.call(.{}, i32);     // Final result
        /// ```
        ///
        /// Errors: `Error.OutOfMemory` if stack allocation fails, `Error.Runtime` if function execution fails
        pub fn call(self: @This(), args: anytype, comptime R: type) !Result(R) {
            try self.ref.lua.checkStack(2);

            stack.push(self.ref.lua, self.ref); // Push function ref

            // Use resume semantics if in a thread, call semantics if in main state
            return self.ref.lua.call(args, R, self.ref.lua.isThread());
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
            stack.push(self.ref.lua, self.ref); // Push function ref
            defer self.state().pop(1); // Remove from stack

            self.state().codegenCompile(-1);
        }

        /// Creates a clone of the function.
        ///
        /// Returns a new function with the same bytecode and upvalue references.
        /// The cloned function is independent but shares upvalue references with
        /// the original. The environment is set to the current global table.
        ///
        /// Example:
        /// ```zig
        /// const func = try lua.globals().get("myFunc", Lua.Function);
        /// defer func.?.deinit();
        ///
        /// const cloned = try func.?.clone();
        /// defer cloned.deinit();
        /// ```
        ///
        /// Returns: `Function` - A new function with copied upvalue references
        /// Errors: `Error.OutOfMemory` if allocation fails
        pub fn clone(self: Function) !Function {
            try self.ref.lua.checkStack(2);

            stack.push(self.ref.lua, self.ref); // Push function ref
            self.state().cloneFunction(-1); // Clone function, pushes clone on stack

            // Create a reference to the cloned function on the stack
            const cloned_ref = Ref.init(self.ref.lua, -1);
            self.state().pop(2); // Pop both original and cloned functions

            return Function{ .ref = cloned_ref };
        }

        /// Sets a breakpoint on the specified line of this function.
        ///
        /// Sets or unsets a breakpoint at the given line number in the function.
        /// When a breakpoint is hit during execution, the `debugbreak` callback will be triggered.
        /// The breakpoint will be set on the closest valid line at or after the specified line.
        ///
        /// Prerequisites:
        /// - Function must be a Lua function (not a C function)
        /// - `debugbreak` callback should be set using `setCallbacks()` to handle breakpoint events
        ///
        /// Arguments:
        /// - `line`: Line number to set the breakpoint on (1-based)
        /// - `enabled`: Whether to enable (true) or disable (false) the breakpoint
        ///
        /// Returns: The actual line number where the breakpoint was set
        /// Errors: `Error.InvalidBreakpoint` if the line is invalid or breakpoint cannot be set
        ///
        /// Example:
        /// ```zig
        /// // Load a multi-line function
        /// _ = try lua.eval(
        ///     \\function test()
        ///     \\    local x = 1  -- line 2
        ///     \\    local y = 2  -- line 3
        ///     \\    return x + y -- line 4
        ///     \\end
        /// , .{}, void);
        ///
        /// const func = try lua.globals().get("test", Lua.Function);
        /// defer func.?.deinit();
        ///
        /// // Set breakpoint on line 3
        /// const actual_line = try func.?.setBreakpoint(3, true);
        /// // actual_line will be 3 if line 3 has executable code
        /// ```
        pub fn setBreakpoint(self: Function, line: i32, enabled: bool) !i32 {
            stack.push(self.ref.lua, self.ref); // Push function ref
            defer self.state().pop(1); // Remove from stack

            const result = self.state().breakpoint(-1, line, enabled);
            return if (result == -1) error.InvalidBreakpoint else result;
        }

        /// Returns the registry reference ID if valid, otherwise null.
        pub inline fn getRef(self: Function) ?c_int {
            return self.ref.getRef();
        }
    };

    /// High-level string buffer for efficient string building in Lua
    ///
    /// StrBuf provides a high-level wrapper around Luau's luaL_Strbuf for efficient
    /// string construction. It manages a growable buffer that can accumulate string
    /// data from various sources and push the final result as a Lua string.
    ///
    /// The buffer uses an internal stack-based storage system. When the internal
    /// buffer is exhausted, a mutable string object is placed on the Lua stack
    /// and the buffer references that instead.
    ///
    /// Example:
    /// ```zig
    /// var buf: Lua.StrBuf = undefined;
    /// buf.init(lua);
    /// buf.addString("Hello");
    /// buf.addChar(' ');
    /// buf.addString("World");
    /// buf.addChar('!');
    /// try globals.set("message", &buf); // Sets global variable to "Hello World!"
    /// ```
    pub const StrBuf = struct {
        buf: State.StrBuf,
        lua: *Self,

        /// Initialize buffer with default size in place
        ///
        /// Creates a new string buffer using Luau's internal buffer size (LUA_BUFFERSIZE).
        /// The buffer starts empty and grows as needed when data is added.
        ///
        /// IMPORTANT: The StrBuf must NOT be moved after initialization. Always create it
        /// as a local variable and use it by reference (&buf) to avoid corrupting internal pointers.
        pub fn init(self: *StrBuf, lua: *Self) void {
            self.lua = lua;
            lua.state.bufInit(&self.buf);
        }

        /// Initialize buffer with specific capacity in place
        ///
        /// Creates a string buffer pre-allocated to hold at least `size` characters.
        /// This can improve performance when the approximate final size is known.
        ///
        /// IMPORTANT: The StrBuf must NOT be moved after initialization. Always create it
        /// as a local variable and use it by reference (&buf) to avoid corrupting internal pointers.
        ///
        /// Example:
        /// ```zig
        /// var buf: Lua.StrBuf = undefined;
        /// buf.initSize(&lua, 100);
        /// buf.addString("Large content goes here...");
        /// try globals.set("content", &buf);
        /// ```
        pub fn initSize(self: *StrBuf, lua: *Self, size: usize) void {
            self.lua = lua;
            _ = lua.state.bufInitSize(&self.buf, size);
        }

        /// Add a single character to the buffer
        ///
        /// Appends one character to the buffer, growing it if necessary.
        /// Uses the luaL_addchar macro for optimal performance.
        ///
        /// Example:
        /// ```zig
        /// buf.addChar('H');
        /// buf.addChar('\n');
        /// ```
        pub fn addChar(self: *StrBuf, char: u8) void {
            // Implement luaL_addchar macro: ((void)((B)->p < (B)->end || luaL_prepbuffsize(B, 1)), (*(B)->p++ = (char)(c)))
            if (self.buf.p >= self.buf.end) {
                _ = State.prepBuffSize(&self.buf, 1);
            }
            self.buf.p[0] = char;
            self.buf.p += 1;
        }

        /// Add a null-terminated string to the buffer
        ///
        /// Appends a null-terminated string to the buffer. The null terminator
        /// is not included in the buffer. Uses strlen internally to determine length.
        ///
        /// For better performance with known-length strings, use `addLString`.
        ///
        /// Example:
        /// ```zig
        /// buf.addString("Hello World");
        /// ```
        pub fn addString(self: *StrBuf, s: [*:0]const u8) void {
            State.addLString(&self.buf, std.mem.span(s));
        }

        /// Add a length-specified string to the buffer
        ///
        /// Appends a string slice to the buffer. This is more efficient than
        /// `addString` when the length is already known, as it avoids strlen.
        ///
        /// Example:
        /// ```zig
        /// const data = "Hello World";
        /// buf.addLString(data);
        /// ```
        pub fn addLString(self: *StrBuf, s: []const u8) void {
            State.addLString(&self.buf, s);
        }

        /// Add any Zig value to the buffer using generic type conversion
        ///
        /// Converts a Zig value to its Lua representation, then to string form,
        /// and adds it to the buffer. This provides type-safe value addition
        /// without manual stack manipulation.
        ///
        /// Type conversions follow the same rules as other Lua bindings:
        /// - Numbers, strings, and booleans are converted directly
        /// - nil values add "nil"
        /// - Other types are converted via their string representation
        ///
        /// Example:
        /// ```zig
        /// try buf.add(@as(i32, 42));     // "42"
        /// try buf.add(@as(f64, 3.14));   // "3.14"
        /// try buf.add(true);             // "true"
        /// try buf.add(@as(?i32, null));  // "nil"
        /// ```
        pub fn add(self: *StrBuf, value: anytype) !void {
            try self.lua.checkStack(1);
            stack.push(self.lua.*, value);
            State.addValueAny(&self.buf, -1);
            self.lua.state.pop(1);
        }
    };

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
    /// try expectEq(result.ok, 42);
    ///
    /// // Execute bytecode that returns nothing
    /// const void_result = try lua.exec(bytecode, void);
    /// try expectEq(void_result, .{ .ok = {} });
    ///
    /// // Execute bytecode with optional return type
    /// const maybe_result = try lua.exec(bytecode, ?f64);
    /// try expectEq(maybe_result.ok, 3.14);
    ///
    /// // Execute bytecode that returns multiple values as a tuple
    /// const tuple = try lua.exec(bytecode, struct { i32, f64, bool });
    /// try expectEq(tuple.ok, .{ 10, 3.14, true });
    /// ```
    ///
    /// Returns: The result of executing the bytecode as a Result union
    /// Errors: `Error.OutOfMemory` if the VM runs out of memory, `Error.Runtime` if execution fails
    pub fn exec(self: Self, blob: []const u8, comptime T: type) !Result(T) {
        // Push byte code onto stack
        {
            const load_status = self.state.load("", blob, 0);

            // Load can either succeed or get an OOM error
            // See https://github.com/luau-lang/luau/blob/66202dc4ac15f39a6ce8f732e2be19b636ee2af1/VM/src/lvmload.cpp#L643
            switch (load_status) {
                .ok => {},
                .errmem => return Error.OutOfMemory,
                else => unreachable,
            }

            std.debug.assert(self.state.isFunction(-1));
        }

        return self.call(.{}, T, false);
    }

    /// Get the current status of this coroutine thread.
    ///
    /// Returns the execution state of the coroutine without resuming it.
    ///
    /// Possible states:
    /// - `.run`: Currently running (only possible if checking from within the coroutine)
    /// - `.sus`: Suspended (either not started or yielded)
    /// - `.nor`: Normal (resumed another coroutine and waiting for it)
    /// - `.fin`: Finished execution successfully
    /// - `.err`: Terminated with an error
    ///
    /// Example:
    /// ```zig
    /// const thread_lua = lua.createThread();
    /// const status = thread_lua.status();
    /// switch (status) {
    ///     .sus => std.debug.print("Coroutine is suspended\n", .{}),
    ///     .fin => std.debug.print("Coroutine has finished\n", .{}),
    ///     else => {},
    /// }
    /// ```
    pub fn status(self: Self) State.CoStatus {
        const main_thread = self.state.mainThread();
        return main_thread.coStatus(self.state);
    }

    /// Check if this coroutine thread is currently yieldable.
    ///
    /// Returns true if the coroutine can yield (i.e., it's currently running
    /// and not in a non-yieldable context like a metamethod).
    ///
    /// Example:
    /// ```zig
    /// const thread_lua = lua.createThread();
    /// if (thread_lua.isYieldable()) {
    ///     // Safe to yield from this context
    /// }
    /// ```
    pub fn isYieldable(self: Self) bool {
        return self.state.isYieldable();
    }

    /// Reset this thread to its initial state.
    ///
    /// Clears the thread's stack and resets it to a fresh state, allowing
    /// it to be reused for a new coroutine. Any previous execution state is lost.
    ///
    /// Example:
    /// ```zig
    /// const thread_lua = lua.createThread();
    /// thread_lua.reset();
    /// // Thread can now be used for a new coroutine
    /// ```
    pub fn reset(self: Self) void {
        self.state.resetThread();
    }

    /// Check if this thread is in a reset state.
    ///
    /// Returns true if the thread has been reset and is ready for reuse.
    ///
    /// Example:
    /// ```zig
    /// const thread_lua = lua.createThread();
    /// if (thread_lua.isReset()) {
    ///     // Thread is ready for a new coroutine
    /// }
    /// ```
    pub fn isReset(self: Self) bool {
        return self.state.isThreadReset();
    }

    /// Get thread-specific data for this thread.
    ///
    /// Each thread can have an associated opaque pointer for storing
    /// thread-local data. This is useful for associating custom state
    /// with specific coroutines.
    ///
    /// Example:
    /// ```zig
    /// const thread_lua = lua.createThread();
    /// // Store custom data
    /// const my_data = try allocator.create(MyData);
    /// thread_lua.setData(my_data);
    ///
    /// // Retrieve custom data
    /// if (thread_lua.getData()) |data| {
    ///     const my_data = @as(*MyData, @ptrCast(@alignCast(data)));
    ///     // Use my_data...
    /// }
    /// ```
    pub fn getData(self: Self) ?*anyopaque {
        return self.state.getThreadData();
    }

    /// Set thread-specific data for this thread.
    pub fn setData(self: Self, data: ?*anyopaque) void {
        self.state.setThreadData(data);
    }

    /// Check if this Lua object is a thread/coroutine.
    ///
    /// Returns `true` if this Lua object represents a thread (coroutine),
    /// `false` if it's the main Lua state.
    ///
    /// This is useful for determining whether `deinit()` should actually
    /// close the state or not, since threads are garbage collected automatically.
    ///
    /// Example:
    /// ```zig
    /// const main_lua = try Lua.init(&allocator);
    /// defer main_lua.deinit(); // This will close the state
    ///
    /// const thread_lua = main_lua.createThread();
    /// defer thread_lua.deinit(); // This will NOT close anything
    ///
    /// if (thread_lua.isThread()) {
    ///     std.debug.print("This is a thread\n", .{});
    /// }
    /// if (!main_lua.isThread()) {
    ///     std.debug.print("This is the main state\n", .{});
    /// }
    /// ```
    pub inline fn isThread(self: Self) bool {
        // Check if the current state is different from the main thread
        const main_thread = self.state.mainThread();
        return self.state.lua != main_thread.lua;
    }

    /// Result of a Lua function call containing status and return value.
    pub fn Result(comptime R: type) type {
        return union(enum) {
            /// Function completed successfully.
            ok: ?R,
            /// Function yielded (suspended execution).
            yield: ?R,
            /// Debug break occurred during execution.
            debugBreak,
        };
    }

    /// Convert status and result to Result union or error.
    fn makeResult(comptime R: type, exec_status: State.Status, result: ?R) !Result(R) {
        return switch (exec_status) {
            .ok => Result(R){ .ok = result },
            .yield => Result(R){ .yield = result },
            .break_debug => Result(R).debugBreak,
            .errmem => error.OutOfMemory,
            else => error.Runtime,
        };
    }

    /// Calls (or resumes) a Lua function with the provided arguments and returns the result.
    fn call(self: Self, args: anytype, comptime R: type, is_resume: bool) !Result(R) {
        // Count and push args - unified logic for both call types
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

        // Execute based on is_resume flag - determine states internally
        const exec_status = if (is_resume) blk: {
            // For resume, we need the main thread state
            const main_thread = self.state.mainThread();
            break :blk self.state.resume_(main_thread, arg_count);
        } else self.state.pcall(arg_count, ret_count, 0);

        switch (exec_status) {
            .ok, .yield => {
                const ret_type_info = @typeInfo(R);
                var result: R = undefined;

                if (ret_type_info == .void) {
                    // No return value expected
                    result = {};
                } else if (ret_type_info == .@"struct") {
                    const info = ret_type_info.@"struct";
                    if (info.is_tuple) {
                        // Pop tuple elements in reverse order (stack is LIFO)
                        inline for (0..info.fields.len) |i| {
                            const field_index = info.fields.len - 1 - i;
                            result[field_index] = stack.pop(self, info.fields[field_index].type).?;
                        }
                    } else {
                        result = stack.pop(self, R).?;
                    }
                } else {
                    result = stack.pop(self, R).?;
                }

                return makeResult(R, exec_status, result);
            },
            else => {
                // Error occurred - return status with null result
                if (self.state.isString(-1)) {
                    if (self.state.toString(-1)) |error_msg| {
                        std.debug.print("Lua error: {s}\n", .{error_msg});
                    }
                }
                self.state.pop(1);

                return makeResult(R, exec_status, null);
            },
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
    pub fn eval(self: Self, source: []const u8, opts: Compiler.Opts, comptime T: type) !Result(T) {
        const result = try Compiler.compile(source, opts);
        defer result.deinit();

        if (result == .err) {
            return Error.Compile;
        }

        const blob = result.ok;
        return self.exec(blob, T);
    }

    /// Creates a metatable for a struct type without registering it globally.
    ///
    /// Iterates over all public and meta functions in the struct to create bindings.
    /// Functions with comptime parameters are not supported and will throw compile time errors.
    ///
    /// The `init` function will be renamed to `new` and treated as a userdata constructor.
    /// If the struct has a `deinit` function, it will be registered with Luau's newUserdataDtor
    /// (see `createUserDataInstance` for implementation specifics).
    ///
    /// Instance methods are supported, but the first parameter must be a userdata pointer.
    /// Metamethods (functions starting with `__`) are also supported.
    ///
    /// Provides flexibility to modify the metatable before use. For simple registration
    /// with global access, use `registerUserData` instead.
    ///
    /// Returns: `Table` - A wrapper around the newly created metatable
    /// Errors: `Error.OutOfMemory` if memory allocation fails
    pub fn createMetaTable(self: Self, comptime T: type) !Table {
        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("createMetaTable can only be used with struct types, got " ++ @typeName(T));
        }

        const type_name: [:0]const u8 = @typeName(T);

        try self.checkStack(1);

        // Create the metatable (leaves it on stack)
        userdata.createMetaTable(T, @constCast(&self.state), type_name);

        // Create a reference to the metatable on the stack
        const metatable_ref = Ref.init(self, -1);
        self.state.pop(1); // Remove metatable from stack

        return Table{ .ref = metatable_ref };
    }

    /// Register a struct type for global access from Lua.
    ///
    /// Creates method bindings and registers the type globally so static methods
    /// are accessible as `TypeName.method()`. Use `createMetaTable` if you need
    /// to modify the metatable before registration.
    ///
    /// Requirements:
    /// - Must be a struct type with public methods
    /// - Functions starting with `__` are treated as metamethods (see userdata module)
    /// - Each type can only be registered once per Lua state
    ///
    /// Errors: `Error.OutOfMemory` if memory allocation fails
    pub fn registerUserData(self: Self, comptime T: type) !void {
        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("registerUserData can only be used with struct types, got " ++ @typeName(T));
        }

        const type_name: [:0]const u8 = @typeName(T);

        try self.checkStack(1);

        // Check if type is already registered
        if (self.state.getField(State.REGISTRYINDEX, type_name) != State.Type.nil) {
            @panic("Type " ++ @typeName(T) ++ " is already registered");
        }
        self.state.pop(1); // Pop nil

        // Create the metatable (leaves it on stack)
        userdata.createMetaTable(T, @constCast(&self.state), type_name);

        // Store the metatable in the registry for userdata type checking
        self.state.pushValue(-1); // Duplicate metatable on stack
        self.state.setField(State.REGISTRYINDEX, type_name); // Store copy in registry

        // Extract just the type name without module prefix for global registration
        // Example: "myapp.data.User" -> "User", "TestUserData" -> "TestUserData"
        const full_type_name = @typeName(T);
        const type_name_only = if (std.mem.lastIndexOf(u8, full_type_name, ".")) |last_dot|
            full_type_name[last_dot + 1 ..]
        else
            full_type_name;

        // Register it globally so static methods are accessible as TypeName.method()
        // Metatable is still on stack, set it as global directly
        self.state.setGlobal(type_name_only);
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

    /// Set a custom assert handler for Luau VM assertions.
    ///
    /// The assert handler is called when a Luau VM assertion fails, allowing custom error
    /// handling and debugging. The handler receives information about the failed assertion
    /// including expression, file, line number, and function name.
    ///
    /// Example:
    /// ```zig
    /// fn myAssertHandler(expr: [*c]const u8, file: [*c]const u8, line: c_int, func: [*c]const u8) callconv(.C) c_int {
    ///     std.debug.print("Assertion failed: {s} at {s}:{} in {s}\n", .{expr, file, line, func});
    ///     return 0; // Return 0 to abort
    /// }
    ///
    /// Lua.setAssertHandler(myAssertHandler);
    /// ```
    ///
    /// Note: The handler function must have C calling convention and return 0 to abort or non-zero to continue.
    pub inline fn setAssertHandler(handler: AssertHandler) void {
        assert.setAssertHandler(handler);
    }

    /// Apply sandbox restrictions to create a secure execution environment.
    ///
    /// This method performs the following security hardening operations:
    /// - Sets all standard library tables (math, string, table, etc.) to read-only
    /// - Sets builtin metatables (string, number) to read-only to prevent metamethod hijacking
    /// - Makes the global environment table read-only to prevent modification
    /// - Activates safe environment mode to isolate global access
    /// - For threads: Creates an isolated global environment that proxies reads to main globals
    ///
    /// This method calls the appropriate Luau sandbox API based on whether this is
    /// the main Lua state or a thread:
    /// - For main state: Calls `luaL_sandbox()` to set all libraries to read-only
    ///   and enable safe environment mode
    /// - For threads: Calls `luaL_sandboxthread()` to create an isolated global
    ///   environment that proxies reads to the main globals
    ///
    /// The sandbox system provides protection against:
    /// - Monkey-patching of built-in functions and libraries
    /// - Global environment pollution between scripts
    /// - Access to dangerous functionality through metatable manipulation
    ///
    /// Note: For the main state, this should be called after `openLibs()` but
    /// before creating threads. For threads, call this before executing any code.
    pub fn sandbox(self: Self) void {
        if (self.isThread()) {
            // This is a thread - create sandboxed global environment
            self.state.sandboxThread();
        } else {
            // This is the main state - protect built-in libraries
            self.state.sandbox();
        }
    }
};

const expect = std.testing.expect;
const expectEq = std.testing.expectEqual;
const expectError = std.testing.expectError;

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

    lua.openLibs();

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

    lua.openLibs();

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

    // Test table length
    const array_table = lua.createTable(.{});
    defer array_table.deinit();

    // Empty table length
    try expectEq(try array_table.len(), 0);

    // Array-like table length
    try array_table.setRaw(1, "first");
    try array_table.setRaw(2, "second");
    try array_table.setRaw(3, "third");
    try expectEq(try array_table.len(), 3);

    // Add more elements
    try array_table.setRaw(4, "fourth");
    try expectEq(try array_table.len(), 4);
}

test "struct and array integration" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.openLibs();

    const Point = struct {
        x: f64,
        y: f64,
        name: []const u8,
    };

    const Config = struct {
        points: [2]Point,
        enabled: bool,
    };

    const config = Config{
        .points = [_]Point{
            Point{ .x = 1.0, .y = 2.0, .name = "start" },
            Point{ .x = 3.0, .y = 4.0, .name = "end" },
        },
        .enabled = true,
    };

    // Test that we can set a global struct variable
    const globals = lua.globals();
    try globals.set("config", config);

    // Test accessing struct fields from Lua
    const first_point_x = try lua.eval("return config.points[1].x", .{}, f64);
    try expectEq(first_point_x.ok, 1.0);

    const first_point_name = try lua.eval("return config.points[1].name", .{}, Lua.Value);
    try expect(std.mem.eql(u8, first_point_name.ok.?.asString().?, "start"));
    first_point_name.ok.?.deinit();

    const second_point_y = try lua.eval("return config.points[2].y", .{}, f64);
    try expectEq(second_point_y.ok, 4.0);

    const enabled = try lua.eval("return config.enabled", .{}, bool);
    try expect(enabled.ok.?);

    // Test array length
    const points_length = try lua.eval("return #config.points", .{}, i32);
    try expectEq(points_length.ok, 2);
}
