//! Guided tour of the luaz library features
//!
//! This example demonstrates the main features of luaz -
//! It shows how to:
//! - Create and manage Lua states
//! - Work with global variables
//! - Execute Lua code
//! - Compile source to bytecode and execute it
//! - Create and manipulate tables
//! - Register Zig functions
//! - Work with user data types
//! - Use Luau's codegen feature

const std = @import("std");
const luaz = @import("luaz");
const print = std.debug.print;

// Example functions for demonstrating Zig function integration
fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn greet(name: []const u8) void {
    print("Hello, {s}!\n", .{name});
}

fn divmod(a: i32, b: i32) struct { i32, i32 } {
    return .{ @divTrunc(a, b), @mod(a, b) };
}

fn safeDivide(a: f64, b: f64) ?f64 {
    if (b == 0) return null;
    return a / b;
}

// Example struct for demonstrating user data
const Counter = struct {
    value: i32,
    name: []const u8,

    pub fn init(start: i32, name: []const u8) Counter {
        return .{ .value = start, .name = name };
    }

    pub fn increment(self: *Counter) void {
        self.value += 1;
    }

    pub fn getValue(self: Counter) i32 {
        return self.value;
    }

    pub fn add(self: Counter, other: i32) i32 {
        return self.value + other;
    }

    // Metamethods
    pub fn __len(self: Counter) i32 {
        return self.value;
    }

    pub fn __tostring(self: Counter) []const u8 {
        return self.name;
    }
};

pub fn main() !void {
    // Create an allocator (you can use any Zig allocator)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // You can create a new Lua state with `Lua.init()`. Pass null to use Luau's
    // default allocator, or pass a Zig allocator for custom memory management.
    const lua = try luaz.Lua.init(&allocator);
    defer lua.deinit();

    // Load the standard Lua libraries
    lua.openLibs();

    print("=== Luaz Guided Tour ===\n\n", .{});

    // Working with global variables
    // You can get and set global variables through the globals() table
    {
        print("-- Global Variables --\n", .{});
        const globals = lua.globals();

        try globals.set("string_var", "hello");
        try globals.set("int_var", 42);
        try globals.set("float_var", 3.14);
        try globals.set("bool_var", true);

        // Reading values back
        const str_val = try globals.get("string_var", []const u8);
        const int_val = try globals.get("int_var", i32);
        const float_val = try globals.get("float_var", f64);
        const bool_val = try globals.get("bool_var", bool);

        print("string_var: {s}\n", .{str_val.?});
        print("int_var: {}\n", .{int_val.?});
        print("float_var: {d:.2}\n", .{float_val.?});
        print("bool_var: {}\n", .{bool_val.?});
    }

    // Evaluating Lua code
    // The eval() function compiles and executes Lua code in one step
    {
        print("\n-- Evaluating Lua Code --\n", .{});

        // Simple arithmetic
        const result1 = try lua.eval("return 2 + 3", .{}, i32);
        print("2 + 3 = {}\n", .{result1});

        // Boolean expressions
        const result2 = try lua.eval("return false == false", .{}, bool);
        print("false == false = {}\n", .{result2});

        // String operations
        try lua.eval("global = 'foo' .. 'bar'", .{}, void);
        const globals = lua.globals();
        const concat = try globals.get("global", []const u8);
        print("'foo' .. 'bar' = {s}\n", .{concat.?});

        // Multiple return values as tuples
        const tuple = try lua.eval("return 10, 2.5, false", .{}, struct { i32, f64, bool });
        print("Multiple returns: {}, {d:.1}, {}\n", .{ tuple[0], tuple[1], tuple[2] });
    }

    // Compiling and executing bytecode
    // For production use, bytecode should be precompiled offline using build tools
    {
        print("\n-- Bytecode Compilation --\n", .{});

        const source_code = "return 5 * 7 + 3";

        // Compile Lua source to bytecode
        const compile_result = try luaz.Compiler.compile(source_code, .{});
        defer compile_result.deinit();

        if (compile_result == .err) {
            print("Compilation failed!\n", .{});
            return;
        }

        const bytecode = compile_result.ok;
        print("Compiled {} bytes of source into {} bytes of bytecode\n", .{ source_code.len, bytecode.len });

        // Execute the same bytecode multiple times
        const result1 = try lua.exec(bytecode, i32);
        print("First execution: {}\n", .{result1});

        const result2 = try lua.exec(bytecode, i32);
        print("Second execution: {}\n", .{result2});

        print("Note: In production, use 'zig build luau-compile' to precompile Lua scripts offline\n", .{});
    }

    // Creating and manipulating tables
    {
        print("\n-- Tables --\n", .{});

        // Create a table with array hints
        const array_table = lua.createTable(.{ .arr = 3 });
        defer array_table.deinit();

        // Set array elements (1-based indexing in Lua)
        try array_table.setRaw(1, "one");
        try array_table.setRaw(2, "two");
        try array_table.setRaw(3, "three");

        // Create a hash table
        const map_table = lua.createTable(.{ .rec = 3 });
        defer map_table.deinit();

        try map_table.set("one", 1);
        try map_table.set("two", 2);
        try map_table.set("three", 3);

        // Read back values
        const v = try map_table.get("two", i32);
        print("map_table['two'] = {}\n", .{v.?});

        // Pass tables to Lua
        const globals = lua.globals();
        try globals.set("array_table", array_table);
        try globals.set("map_table", map_table);

        // Iterate over tables in Lua
        try lua.eval(
            \\print("Array table:")
            \\for k, v in pairs(array_table) do
            \\    print("  " .. k .. " = " .. v)
            \\end
            \\print("Map table:")
            \\for k, v in pairs(map_table) do
            \\    print("  " .. k .. " = " .. v)
            \\end
        , .{}, void);
    }

    // Registering Zig functions
    {
        print("\n-- Zig Functions in Lua --\n", .{});

        const globals = lua.globals();
        try globals.set("add", add);
        try globals.set("greet", greet);
        try globals.set("divmod", divmod);
        try globals.set("safeDivide", safeDivide);

        // Call from Lua
        const sum = try lua.eval("return add(10, 20)", .{}, i32);
        print("add(10, 20) = {}\n", .{sum});

        try lua.eval("greet('Zig')", .{}, void);

        const dm = try lua.eval("return divmod(17, 5)", .{}, struct { i32, i32 });
        print("divmod(17, 5) = {}, {}\n", .{ dm[0], dm[1] });

        // Optional returns become nil in Lua
        try lua.eval(
            \\local result = safeDivide(10, 0)
            \\if result == nil then
            \\    print("Division by zero!")
            \\else
            \\    print("Result: " .. result)
            \\end
        , .{}, void);
    }

    // Working with user data
    {
        print("\n-- User Data --\n", .{});

        // Register the user data type
        try lua.registerUserData(Counter);

        // Use from Lua
        try lua.eval(
            \\-- Create new counter (init becomes 'new' in Lua)
            \\local c = Counter.new(10, "my_counter")
            \\print("Initial value: " .. c:getValue())
            \\
            \\-- Call methods
            \\c:increment()
            \\c:increment()
            \\print("After increment: " .. c:getValue())
            \\
            \\-- Methods can take parameters
            \\local sum = c:add(5)
            \\print("12 + 5 = " .. sum)
            \\
            \\-- Metamethods demonstration
            \\print("Length of counter: " .. #c)  -- Uses __len
            \\print("Counter as string: " .. tostring(c))  -- Uses __tostring
        , .{}, void);
    }

    // Advanced: Using Luau's codegen feature
    {
        print("\n-- Luau Codegen --\n", .{});

        if (lua.enable_codegen()) {
            print("Code generation enabled!\n", .{});

            // Define a compute-intensive function
            _ = try lua.eval(
                \\function fibonacci(n)
                \\    if n <= 1 then return n end
                \\    return fibonacci(n - 1) + fibonacci(n - 2)
                \\end
            , .{}, void);

            // Compile the function for better performance
            const globals = lua.globals();
            try globals.compile("fibonacci");

            // Now the function runs with native code
            const fib10 = try lua.eval("return fibonacci(10)", .{}, i32);
            print("fibonacci(10) = {} (compiled with codegen)\n", .{fib10});
        } else {
            print("Code generation not supported on this platform\n", .{});
        }
    }

    // Working with vectors (Luau-specific feature)
    {
        print("\n-- Vectors --\n", .{});

        // Luau supports native vector types (configured size, typically 3 or 4 components)
        const vec3 = @Vector(3, f32){ 1.0, 2.0, 3.0 };
        const globals = lua.globals();
        try globals.set("myVector", vec3);

        try lua.eval(
            \\print("Vector: " .. tostring(myVector))
            \\-- Vectors support component access
            \\print("X component: " .. myVector.X)
            \\print("Y component: " .. myVector.Y)
            \\print("Z component: " .. myVector.Z)
        , .{}, void);
    }

    // Error handling
    {
        print("\n-- Error Handling --\n", .{});

        // Compilation errors
        const compile_result = lua.eval("return 1 + '", .{}, i32);
        if (compile_result) |_| {
            print("Unexpected success\n", .{});
        } else |err| {
            print("Caught compilation error: {}\n", .{err});
        }

        // Runtime errors are handled by Lua's error system
        // You can use pcall in Lua for protected calls
        try lua.eval(
            \\local success, result = pcall(function()
            \\    error("This is a runtime error")
            \\end)
            \\if not success then
            \\    print("Caught runtime error: " .. result)
            \\end
        , .{}, void);
    }

    print("\n=== Tour Complete! ===\n", .{});
}
