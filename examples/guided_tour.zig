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
//! - Push and retrieve arrays
//! - Work with tuples and table-based structures
//! - Control garbage collection for memory management
//! - Work with coroutines and threads
//! - Build strings efficiently with StrBuf

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

    pub fn __add(self: Counter, other: i32) Counter {
        return Counter{
            .value = self.value + other,
            .name = self.name,
        };
    }

    pub fn __sub(self: Counter, other: i32) Counter {
        return Counter{
            .value = self.value - other,
            .name = self.name,
        };
    }

    pub fn __mul(self: Counter, other: i32) Counter {
        return Counter{
            .value = self.value * other,
            .name = self.name,
        };
    }

    pub fn __div(self: Counter, other: i32) Counter {
        return Counter{
            .value = @divTrunc(self.value, other),
            .name = self.name,
        };
    }

    pub fn __idiv(self: Counter, other: i32) Counter {
        return Counter{
            .value = @divFloor(self.value, other),
            .name = self.name,
        };
    }

    pub fn __mod(self: Counter, other: i32) Counter {
        return Counter{
            .value = @mod(self.value, other),
            .name = self.name,
        };
    }

    pub fn __pow(self: Counter, other: i32) Counter {
        return Counter{
            .value = std.math.pow(i32, self.value, other),
            .name = self.name,
        };
    }

    pub fn __unm(self: Counter) Counter {
        return Counter{
            .value = -self.value,
            .name = self.name,
        };
    }

    pub fn __eq(self: Counter, other: Counter) bool {
        return self.value == other.value;
    }

    pub fn __lt(self: Counter, other: Counter) bool {
        return self.value < other.value;
    }

    pub fn __le(self: Counter, other: Counter) bool {
        return self.value <= other.value;
    }

    pub fn __concat(self: Counter, other: []const u8) []const u8 {
        // For simplicity, return a static string based on counter name
        // In real code, you'd want to use an allocator or return a static string
        return if (std.mem.eql(u8, self.name, "my_counter") and std.mem.eql(u8, other, "_test"))
            "my_counter_test"
        else
            "counter_concat";
    }
};

pub fn main() !void {
    // Create an allocator (you can use any Zig allocator)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // You can create a new Lua state with `Lua.init()`. Pass null to use Luau's
    // default allocator, or pass a Zig allocator for custom memory management.
    var lua = try luaz.Lua.init(&allocator);
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
            \\
            \\-- Arithmetic metamethods
            \\local c_plus = c + 5  -- Uses __add
            \\print("After c + 5: " .. c_plus:getValue())
            \\local c_minus = c - 2  -- Uses __sub  
            \\print("After c - 2: " .. c_minus:getValue())
            \\local c_times = c * 3  -- Uses __mul
            \\print("After c * 3: " .. c_times:getValue())
            \\local c_div = c / 2  -- Uses __div
            \\print("After c / 2: " .. c_div:getValue())
            \\local c_idiv = c // 3  -- Uses __idiv (floor division)
            \\print("After c // 3: " .. c_idiv:getValue())
            \\local c_mod = c % 7  -- Uses __mod
            \\print("After c % 7: " .. c_mod:getValue())
            \\local c_pow = c ^ 2  -- Uses __pow
            \\print("After c ^ 2: " .. c_pow:getValue())
            \\local c_neg = -c  -- Uses __unm (unary minus)
            \\print("After -c: " .. c_neg:getValue())
            \\
            \\-- Comparison metamethods
            \\local c2 = Counter.new(15, "counter2")
            \\print("c == c: " .. tostring(c == c))  -- Uses __eq
            \\print("c < c2: " .. tostring(c < c2))  -- Uses __lt
            \\print("c <= c2: " .. tostring(c <= c2))  -- Uses __le
            \\
            \\-- Concatenation metamethod
            \\local concat_result = c .. "_test"  -- Uses __concat
            \\print("c .. \"_test\": " .. concat_result)
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

    // Working with arrays
    {
        print("\n-- Arrays --\n", .{});

        const globals = lua.globals();

        // Push various array types
        const int_array = [_]i32{ 10, 20, 30, 40, 50 };
        const string_array = [_][]const u8{ "apple", "banana", "cherry" };
        const bool_array = [_]bool{ true, false, true };

        try globals.set("numbers", int_array);
        try globals.set("fruits", string_array);
        try globals.set("flags", bool_array);

        try lua.eval(
            \\print("Integer array:")
            \\for i, v in ipairs(numbers) do
            \\    print("  " .. i .. ": " .. v)
            \\end
            \\
            \\print("String array:")
            \\for i, v in ipairs(fruits) do
            \\    print("  " .. i .. ": " .. v)
            \\end
            \\
            \\print("Boolean array:")
            \\for i, v in ipairs(flags) do
            \\    print("  " .. i .. ": " .. tostring(v))
            \\end
        , .{}, void);

        // Multiple values can be retrieved as tuples using multiple return values
        const retrieved_numbers = try lua.eval("return 100, 200, 300", .{}, struct { i32, i32, i32 });
        print("Retrieved multiple values from Lua: {}, {}, {}\n", .{ retrieved_numbers[0], retrieved_numbers[1], retrieved_numbers[2] });
    }

    // Working with tuples and table structures
    {
        print("\n-- Tuples and Table Structures --\n", .{});

        const globals = lua.globals();

        // Tuples (anonymous structs) are supported using multiple return values
        const retrieved_tuple = try lua.eval("return 99, 'world', false", .{}, struct { i32, []const u8, bool });
        print("Retrieved tuple: {}, {s}, {}\n", .{ retrieved_tuple[0], retrieved_tuple[1], retrieved_tuple[2] });

        // For named fields, create tables manually
        const point_table = lua.createTable(.{ .rec = 2 });
        defer point_table.deinit();

        try point_table.set("x", 10.5);
        try point_table.set("y", 20.7);
        try globals.set("point", point_table);

        try lua.eval("print('Point: x=' .. point.x .. ', y=' .. point.y)", .{}, void);

        // Retrieve individual fields from table structures
        const x_coord = try point_table.get("x", f32);
        const y_coord = try point_table.get("y", f32);
        print("Retrieved point coordinates: x={d:.1}, y={d:.1}\n", .{ x_coord.?, y_coord.? });
    }

    // Garbage collection control
    {
        print("\n-- Garbage Collection --\n", .{});

        const gc = lua.gc();

        // Monitor memory usage
        const initial_memory_kb = gc.count();
        const initial_memory_bytes = gc.countBytes();
        const initial_total = initial_memory_kb * 1024 + initial_memory_bytes;
        print("Initial memory usage: {} bytes ({} KB + {} bytes)\n", .{ initial_total, initial_memory_kb, initial_memory_bytes });

        // Create some objects to increase memory usage
        try lua.eval(
            \\local large_table = {}
            \\for i = 1, 1000 do
            \\    large_table[i] = "String number " .. i .. " with some extra data to use more memory"
            \\end
            \\global_table = large_table  -- Keep reference to prevent immediate collection
        , .{}, void);

        const after_alloc_memory = gc.count();
        print("Memory after allocation: {} KB (increased by {} KB)\n", .{ after_alloc_memory, after_alloc_memory - initial_memory_kb });

        // Force garbage collection
        print("Running full garbage collection...\n", .{});
        gc.collect();
        const after_gc_memory = gc.count();
        print("Memory after GC: {} KB\n", .{after_gc_memory});

        // Fine-tune GC parameters
        print("Adjusting GC parameters...\n", .{});
        const old_goal = gc.setGoal(150); // Start GC at 50% memory increase
        const old_stepmul = gc.setStepMul(300); // More aggressive GC
        const old_stepsize = gc.setStepSize(2048); // Larger GC steps
        print("Previous GC settings - Goal: {}, StepMul: {}, StepSize: {}\n", .{ old_goal, old_stepmul, old_stepsize });

        // Demonstrate manual GC control
        print("Stopping GC for manual control...\n", .{});
        gc.stop();
        print("GC running: {}\n", .{gc.isRunning()});

        // Create more garbage while GC is stopped
        try lua.eval("global_table = nil", .{}, void); // Release reference
        try lua.eval(
            \\for i = 1, 100 do
            \\    local temp = {}
            \\    for j = 1, 50 do
            \\        temp[j] = "Temporary string " .. i .. "," .. j
            \\    end
            \\end
        , .{}, void);

        // Perform stepped collection
        print("Performing manual GC steps...\n", .{});
        var steps: u32 = 0;
        while (!gc.step(200) and steps < 5) {
            steps += 1;
            print("GC step {} completed\n", .{steps});
        }
        print("GC cycle completed in {} steps\n", .{steps});

        // Restart normal GC
        gc.restart();
        print("GC restarted, running: {}\n", .{gc.isRunning()});

        // Restore original GC parameters
        _ = gc.setGoal(old_goal);
        _ = gc.setStepMul(old_stepmul);
        _ = gc.setStepSize(old_stepsize);
        print("GC parameters restored\n", .{});

        const final_memory = gc.count();
        print("Final memory usage: {} KB\n", .{final_memory});
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

    // Coroutines and threads
    {
        print("\n-- Coroutines and Threads --\n", .{});

        // Create a coroutine function in global scope
        _ = try lua.eval(
            \\function accumulator()
            \\    local sum = 0
            \\    while true do
            \\        local value = coroutine.yield(sum)
            \\        if value == nil then break end
            \\        sum = sum + value
            \\    end
            \\    return sum
            \\end
        , .{}, void);

        const thread = lua.createThread();
        const func = try thread.globals().get("accumulator", luaz.Lua.Function);
        defer func.?.deinit();

        // Start the coroutine - yields initial sum (0)
        const result1 = try func.?.call(.{}, i32);
        print("Start: sum={}\n", .{result1});

        // Continue with values to accumulate
        const result2 = try func.?.call(.{10}, i32);
        print("Add 10: sum={}\n", .{result2});

        const result3 = try func.?.call(.{25}, i32);
        print("Add 25: sum={}\n", .{result3});

        // Send nil to finish
        const final_result = try func.?.call(.{@as(?i32, null)}, i32);
        print("Final: sum={}\n", .{final_result});
    }

    // String Buffer (StrBuf) for efficient string building
    {
        print("\n-- String Buffer (StrBuf) --\n", .{});

        // Build strings efficiently with mixed types
        var buf: luaz.Lua.StrBuf = undefined;
        buf.init(&lua);
        buf.addString("User #");
        try buf.add(@as(i32, 42));
        buf.addString(" logged in at ");
        try buf.add(@as(f64, 3.14));
        buf.addString(" seconds");

        const globals = lua.globals();
        try globals.set("message", &buf);
        const message = try globals.get("message", []const u8);
        print("Built string: {s}\n", .{message.?});

        // Return StrBuf from Zig functions
        const formatMessage = struct {
            fn call(l: *luaz.Lua, name: []const u8, age: i32) !luaz.Lua.StrBuf {
                var b: luaz.Lua.StrBuf = undefined;
                b.init(l);
                b.addLString(name);
                b.addString(" is ");
                try b.add(age);
                b.addString(" years old");
                return b;
            }
        }.call;

        try globals.setClosure("formatMessage", &lua, formatMessage);
        const result = try lua.eval("return formatMessage('Alice', 25)", .{}, []const u8);
        print("From function: {s}\n", .{result});
    }

    print("\n=== Tour Complete! ===\n", .{});
}
