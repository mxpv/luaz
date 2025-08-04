comptime {
    _ = @import("compile.zig");
    _ = @import("lua.zig");
    _ = @import("state.zig");
}

const std = @import("std");
const Lua = @import("lua.zig").Lua;

const Error = Lua.Error;
const State = @import("state.zig").State;

const expect = std.testing.expect;
const expectEq = std.testing.expectEqual;

test "globals access" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const globals = lua.globals();

    // Basic get/set operations
    try globals.set("x", 42);
    try expectEq(try globals.get("x", i32), 42);

    try globals.set("flag", true);
    try expect((try globals.get("flag", bool)).?);

    try expectEq(try globals.get("nonexistent", i32), null);

    // Test different types
    try globals.set("testValue", 42);
    try globals.set("testFlag", true);
    try expectEq(try globals.get("testValue", i32), 42);
    try expectEq(try globals.get("testFlag", bool), true);

    // Set more values and verify through Lua eval
    try globals.set("newValue", 123);
    try globals.set("newFlag", false);
    try expectEq(try lua.eval("return newValue", .{}, i32), 123);
    try expectEq(try lua.eval("return newFlag", .{}, bool), false);

    try expectEq(lua.top(), 0);
}

test "tuple as indexed table accessibility from Lua" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Create table explicitly instead of using tuple push
    const table = lua.createTable(.{ .arr = 4, .rec = 0 });
    defer table.deinit();

    try table.set(1, 42);
    try table.set(2, 3.14);
    try table.set(3, "hello");
    try table.set(4, true);

    try lua.globals().set("tupleTable", table);

    // Access elements from Lua using 1-based indexing
    try expectEq(try lua.eval("return tupleTable[1]", .{}, i32), 42);
    try expectEq(try lua.eval("return tupleTable[2]", .{}, f32), 3.14);
    try expect(try lua.eval("return tupleTable[4]", .{}, bool));

    // Verify tuple table length
    try expectEq(try lua.eval("return #tupleTable", .{}, i32), 4);
}

test "eval function" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test basic eval
    const result = try lua.eval("return 2 + 3", .{}, i32);
    try expectEq(result, 5);

    // Test eval with void return
    try lua.eval("x = 42", .{}, void);
    const globals = lua.globals();
    try expectEq(try globals.get("x", i32), 42);

    // Test eval with tuple return
    const tuple = try lua.eval("return 10, 2.5, false", .{}, struct { i32, f64, bool });
    try expectEq(tuple[0], 10);
    try expectEq(tuple[1], 2.5);
    try expect(!tuple[2]);

    try expectEq(lua.top(), 0);
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

// Test functions with various signatures
fn testNoArgs() i32 {
    return 42;
}

fn testVoidReturn(x: i32) void {
    _ = x; // consume parameter
}

fn testMultipleArgs(a: i32, b: f32, c: bool) f32 {
    const bonus: f32 = if (c) 1.0 else 0.0;
    return @as(f32, @floatFromInt(a)) + b + bonus;
}

fn testOptionalReturn(x: i32) ?i32 {
    return if (x > 0) x * 2 else null;
}

fn testMixedTypes(n: i32, s: []const u8, flag: bool) struct { i32, []const u8, bool } {
    return .{ n + 1, s, !flag };
}

test "Zig function integration" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const globals = lua.globals();

    // Test 1: Simple function with two arguments
    try globals.set("add", testAdd);
    const sum = try lua.eval("return add(10, 20)", .{}, i32);
    try expectEq(sum, 30);

    // Test 2: Function with no arguments
    try globals.set("noArgs", testNoArgs);
    const result = try lua.eval("return noArgs()", .{}, i32);
    try expectEq(result, 42);

    // Test 3: Function with void return
    try globals.set("voidFunc", testVoidReturn);
    try lua.eval("voidFunc(123)", .{}, void);

    // Test 4: Function with multiple different argument types
    try globals.set("multiArgs", testMultipleArgs);
    const multi_result = try lua.eval("return multiArgs(5, 2.5, true)", .{}, f32);
    try expectEq(multi_result, 8.5); // 5 + 2.5 + 1.0

    // Test 5: Function with string arguments
    try globals.set("strlen", testStringArg);
    const len = try lua.eval("return strlen('hello')", .{}, i32);
    try expectEq(len, 5);

    // Test 6: Function returning optional (some value)
    try globals.set("optionalFunc", testOptionalReturn);
    const opt_some = try lua.eval("return optionalFunc(10)", .{}, ?i32);
    try expectEq(opt_some, 20);

    // Test 7: Function returning optional (null value)
    // Note: When Zig function returns null, it becomes nil in Lua,
    // and we need to handle it appropriately when calling from Lua
    try lua.eval("result = optionalFunc(-5)", .{}, void);
    const is_nil = try lua.eval("return result == nil", .{}, bool);
    try expect(is_nil);

    // Test 8: Function returning tuple (multiple separate values)
    try globals.set("tupleFunc", testTupleReturn);
    const tuple_result = try lua.eval("return tupleFunc(15, 3.5)", .{}, struct { i32, f32, bool });
    try expectEq(tuple_result[0], 30); // 15 * 2
    try expectEq(tuple_result[1], 7.0); // 3.5 * 2.0
    try expect(tuple_result[2]); // 15 > 10 = true

    // Test 9: Function with mixed types returning tuple
    try globals.set("mixedFunc", testMixedTypes);
    const mixed_result = try lua.eval("return mixedFunc(10, 'test', false)", .{}, struct { i32, []const u8, bool });
    try expectEq(mixed_result[0], 11); // 10 + 1
    try expect(std.mem.eql(u8, mixed_result[1], "test"));
    try expect(mixed_result[2]); // !false = true

    try expectEq(lua.top(), 0);
}

test "compilation error handling" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const compile_error = lua.eval("return 1 + '", .{}, i32);
    try expect(compile_error == Error.Compile);

    try expectEq(lua.top(), 0);
}

test "table call function" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.state.openLibs(); // Need this for error() function

    _ = try lua.eval(
        \\function add(a, b) return a + b end
        \\function error_func() error('Test runtime error') end
    , .{}, void);

    const globals = lua.globals();

    // Test successful function call
    const result = try globals.call("add", .{ 10, 20 }, i32);
    try expectEq(result, 30);

    // Test error handling - should print debug message and return Error.Runtime
    const error_result = globals.call("error_func", .{}, void);
    try std.testing.expectError(Lua.Error.Runtime, error_result);

    try expectEq(lua.top(), 0);
}

test "function call from global namespace" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.state.openLibs();

    _ = try lua.eval(
        \\function sum(a, b) return a + b end
        \\function divide_error(a, b) if b == 0 then error('Division by zero') end return a / b end
    , .{}, void);

    const globals = lua.globals();

    // Test successful function call
    const func = try globals.get("sum", Lua.Function);
    try expect(func != null);
    defer func.?.deinit();

    const result = try func.?.call(.{ 15, 25 }, i32);
    try expectEq(result, 40);

    // Test error handling with Function.call
    const error_func = try globals.get("divide_error", Lua.Function);
    try expect(error_func != null);
    defer error_func.?.deinit();

    const error_result = error_func.?.call(.{ 10, 0 }, f64);
    try std.testing.expectError(Lua.Error.Runtime, error_result);

    try expectEq(lua.top(), 0);
}

test "func ref compile" {
    const lua = try Lua.init(&std.testing.allocator);
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

test "table func compile" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    if (lua.enable_codegen()) {
        _ = try lua.eval("function square(x) return x * x end", .{}, void);

        try lua.globals().compile("square");

        try expectEq(try lua.eval("return square(5)", .{}, i32), 25);
        try expectEq(try lua.eval("return square(10)", .{}, i32), 100);
    }
}

const TestUserData = struct {
    value: i32,
    name: []const u8,

    pub fn init(initial_value: i32, name: []const u8) TestUserData {
        return TestUserData{
            .value = initial_value,
            .name = name,
        };
    }

    pub fn getValue(self: TestUserData) i32 {
        return self.value;
    }

    pub fn setValue(self: *TestUserData, new_value: i32) void {
        self.value = new_value;
    }

    pub fn getName(self: TestUserData) []const u8 {
        return self.name;
    }

    pub fn add(self: TestUserData, other: i32) i32 {
        return self.value + other;
    }

    // Static functions (no Self parameter)
    pub fn getVersion() i32 {
        return 1;
    }

    pub fn multiply(a: i32, b: i32) i32 {
        return a * b;
    }
};

test "userdata registration and basic functionality" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Load standard libraries to get assert function
    lua.state.openLibs();

    // Register the TestUserData type
    try lua.registerUserData(TestUserData);

    // Single comprehensive Lua script testing all userdata operations
    const test_script =
        \\-- Test static functions
        \\assert(TestUserData.getVersion() == 1, "getVersion should return 1")
        \\assert(TestUserData.multiply(6, 7) == 42, "multiply(6, 7) should return 42")
        \\
        \\-- Create userdata instance using constructor (init -> new mapping)
        \\local obj = TestUserData.new(100, "test_object")
        \\assert(obj ~= nil, "Constructor should create userdata instance")
        \\
        \\-- Test instance methods
        \\assert(obj:getValue() == 100, "getValue should return initial value 100")
        \\assert(obj:getName() == "test_object", "getName should return 'test_object'")
        \\assert(obj:add(50) == 150, "add(50) should return 150")
        \\
        \\-- Test mutable instance method
        \\obj:setValue(200)
        \\assert(obj:getValue() == 200, "getValue should return 200 after setValue(200)")
        \\
        \\-- Test instance method after mutation
        \\assert(obj:add(25) == 225, "add(25) should return 225 after setValue(200)")
        \\
        \\-- Create another instance to verify independence
        \\local obj2 = TestUserData.new(10, "second")
        \\assert(obj2:getValue() == 10, "Second object should have independent value")
        \\assert(obj2:getName() == "second", "Second object should have independent name")
        \\
        \\-- Verify first object wasn't affected
        \\assert(obj:getValue() == 200, "First object should still have value 200")
        \\assert(obj:getName() == "test_object", "First object should still have name 'test_object'")
    ;

    // Execute the comprehensive test script
    try lua.eval(test_script, .{}, void);

    try expectEq(lua.top(), 0);
}

// Global counter to track deinit calls for testing
var deinit_call_count: i32 = 0;

const TestUserDataWithDeinit = struct {
    pub fn init() @This() {
        return @This(){};
    }

    pub fn deinit(self: *TestUserDataWithDeinit) void {
        _ = self; // Consume parameter
        deinit_call_count += 1;
    }
};

test "userdata with destructor support" {
    // Reset counter
    deinit_call_count = 0;

    {
        const lua = try Lua.init(&std.testing.allocator);
        defer lua.deinit();

        // Load standard libraries
        lua.state.openLibs();

        // Register the TestUserDataWithDeinit type
        try lua.registerUserData(TestUserDataWithDeinit);

        // Create objects that should trigger destructors when Lua state is destroyed
        try lua.eval("local obj1 = TestUserDataWithDeinit.new(10, 'obj1')", .{}, void);
        try lua.eval("local obj2 = TestUserDataWithDeinit.new(20, 'obj2')", .{}, void);

        try expectEq(lua.top(), 0);
    } // Lua state destroyed here, destructors should be called

    // Verify that deinit was called for both objects
    try expectEq(deinit_call_count, 2);
}

// Test function that accepts a Table parameter to verify checkArg functionality
fn checkTable(table: Lua.Table) i32 {
    defer table.deinit(); // Properly clean up the table reference
    const value = table.get("key", i32) catch return -1;
    return value orelse -1;
}

test "checkArg with Table parameter" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Register our test function that takes a Table parameter
    const globals = lua.globals();
    try globals.set("processTable", checkTable);

    // Create a table in Lua and call our function
    const result = try lua.eval(
        \\local tbl = {key = 42}
        \\return processTable(tbl)
    , .{}, i32);

    try expectEq(result, 42);
    try expectEq(lua.top(), 0);
}

test "light userdata through globals" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test data to use as light userdata
    // IMPORTANT: test_data must remain alive for as long as the pointer is used in Lua
    var test_data: i32 = 42;
    const test_ptr: *i32 = &test_data;

    // Test storing and retrieving light userdata through globals
    const globals = lua.globals();
    try globals.set("myPtr", test_ptr);

    // Verify we can get the pointer back
    const retrieved_ptr = try globals.get("myPtr", *i32);
    try expect(retrieved_ptr != null);
    try expectEq(retrieved_ptr.?.*, 42);

    // Modify the data through the retrieved pointer
    retrieved_ptr.?.* = 100;
    try expectEq(test_data, 100);

    try expectEq(lua.top(), 0);
}

// Test function that takes light userdata as argument
fn testLightUserdataFunc(ptr: *i32) i32 {
    return ptr.* * 2;
}

test "light userdata function arguments" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    var test_data: i32 = 21;
    const test_ptr: *i32 = &test_data;

    // Register the function and test light userdata as argument
    const globals = lua.globals();
    try globals.set("testFunc", testLightUserdataFunc);
    try globals.set("testPtr", test_ptr);

    // Call the function with light userdata argument through Lua eval
    const result = try lua.eval("return testFunc(testPtr)", .{}, i32);
    try expectEq(result, 42);

    try expectEq(lua.top(), 0);
}

test "light userdata with different pointer types" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test with different data types
    var float_data: f64 = 3.14159;
    var bool_data: bool = true;
    var struct_data = struct { x: i32, y: i32 }{ .x = 10, .y = 20 };

    const float_ptr: *f64 = &float_data;
    const bool_ptr: *bool = &bool_data;
    const struct_ptr: *@TypeOf(struct_data) = &struct_data;

    const globals = lua.globals();

    // Test f64 pointer through globals
    try globals.set("floatPtr", float_ptr);
    const retrieved_float_ptr = try globals.get("floatPtr", *f64);
    try expect(retrieved_float_ptr != null);
    try expectEq(retrieved_float_ptr.?.*, 3.14159);

    // Test bool pointer through globals
    try globals.set("boolPtr", bool_ptr);
    const retrieved_bool_ptr = try globals.get("boolPtr", *bool);
    try expect(retrieved_bool_ptr != null);
    try expectEq(retrieved_bool_ptr.?.*, true);

    // Test struct pointer through globals
    try globals.set("structPtr", struct_ptr);
    const retrieved_struct_ptr = try globals.get("structPtr", *@TypeOf(struct_data));
    try expect(retrieved_struct_ptr != null);
    try expectEq(retrieved_struct_ptr.?.x, 10);
    try expectEq(retrieved_struct_ptr.?.y, 20);

    try expectEq(lua.top(), 0);
}

// Test functions for userdata checkArg support
fn processCounterPtr(counter_ptr: *TestUserData) i32 {
    return counter_ptr.value * 2;
}

fn processCounterVal(counter: TestUserData) i32 {
    return counter.value + 100;
}

test "checkArg userdata support" {
    var lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.state.openLibs();

    // Register TestUserData userdata type (reuse existing type)
    try lua.registerUserData(TestUserData);

    // Register our test functions that use userdata parameters
    const globals = lua.globals();
    try globals.set("processPtr", processCounterPtr);
    try globals.set("processVal", processCounterVal);

    // Test pointer userdata parameter (*TestUserData)
    const ptr_result = try lua.eval(
        \\local counter = TestUserData.new(42, "test")
        \\return processPtr(counter)
    , .{}, i32);

    try expectEq(ptr_result, 84); // 42 * 2

    // Test value userdata parameter (TestUserData)
    const val_result = try lua.eval(
        \\local counter = TestUserData.new(42, "test")
        \\return processVal(counter)
    , .{}, i32);

    try expectEq(val_result, 142); // 42 + 100

    try expectEq(lua.top(), 0);
}

fn testAssertHandler(expr: [*c]const u8, file: [*c]const u8, line: c_int, func: [*c]const u8) callconv(.C) c_int {
    _ = expr;
    _ = file;
    _ = line;
    _ = func;
    return 1; // Continue execution
}

test "assert handler" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Verify the API works by setting and resetting the handler
    Lua.setAssertHandler(testAssertHandler);
    Lua.setAssertHandler(null);
}

const TestUserDataWithMetaMethods = struct {
    const Self = @This();

    size: i32,
    name: []const u8,

    pub fn init(size: i32, name: []const u8) Self {
        return Self{
            .size = size,
            .name = name,
        };
    }

    pub fn add(self: *Self, value: i32) void {
        self.size += value;
    }

    pub fn __len(self: Self) i32 {
        return self.size;
    }

    pub fn __tostring(self: Self) []const u8 {
        return self.name;
    }

    pub fn __add(self: Self, other: i32) Self {
        return Self{
            .size = self.size + other,
            .name = self.name,
        };
    }

    pub fn __sub(self: Self, other: i32) Self {
        return Self{
            .size = self.size - other,
            .name = self.name,
        };
    }

    pub fn __mul(self: Self, other: i32) Self {
        return Self{
            .size = self.size * other,
            .name = self.name,
        };
    }

    pub fn __div(self: Self, other: i32) Self {
        return Self{
            .size = @divTrunc(self.size, other),
            .name = self.name,
        };
    }

    pub fn __idiv(self: Self, other: i32) Self {
        return Self{
            .size = @divFloor(self.size, other),
            .name = self.name,
        };
    }

    pub fn __mod(self: Self, other: i32) Self {
        return Self{
            .size = @mod(self.size, other),
            .name = self.name,
        };
    }

    pub fn __pow(self: Self, other: i32) Self {
        return Self{
            .size = std.math.pow(i32, self.size, other),
            .name = self.name,
        };
    }

    pub fn __unm(self: Self) Self {
        return Self{
            .size = -self.size,
            .name = self.name,
        };
    }

    pub fn __eq(self: Self, other: Self) bool {
        return self.size == other.size;
    }

    pub fn __lt(self: Self, other: Self) bool {
        return self.size < other.size;
    }

    pub fn __le(self: Self, other: Self) bool {
        return self.size <= other.size;
    }

    pub fn __concat(self: Self, other: []const u8) []const u8 {
        // For simplicity, just return the object's name with a suffix
        // In real code, you'd want to use an allocator or return a static string
        return if (std.mem.eql(u8, self.name, "test_object") and std.mem.eql(u8, other, "suffix"))
            "test_object_suffix"
        else
            "test_object_concat";
    }
};

test "userdata with metamethods" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.state.openLibs();
    try lua.registerUserData(TestUserDataWithMetaMethods);

    const test_script =
        \\local obj = TestUserDataWithMetaMethods.new(5, "test_object")
        \\
        \\-- Test __len metamethod
        \\assert(#obj == 5)
        \\obj:add(3)
        \\assert(#obj == 8)
        \\
        \\-- Test __tostring metamethod
        \\assert(tostring(obj) == "test_object")
        \\
        \\-- Test __add metamethod
        \\local obj_added = obj + 2
        \\assert(#obj_added == 10) -- 8 + 2
        \\assert(tostring(obj_added) == "test_object")
        \\
        \\-- Test __sub metamethod
        \\local obj_subbed = obj - 3
        \\assert(#obj_subbed == 5) -- 8 - 3
        \\assert(tostring(obj_subbed) == "test_object")
        \\
        \\-- Test __mul metamethod
        \\local obj_multed = obj * 2
        \\assert(#obj_multed == 16) -- 8 * 2
        \\assert(tostring(obj_multed) == "test_object")
        \\
        \\-- Test __div metamethod
        \\local obj_dived = obj / 2
        \\assert(#obj_dived == 4) -- 8 / 2
        \\assert(tostring(obj_dived) == "test_object")
        \\
        \\-- Test __idiv metamethod
        \\local obj_idived = obj // 3
        \\assert(#obj_idived == 2) -- 8 // 3 = floor(8/3) = 2
        \\assert(tostring(obj_idived) == "test_object")
        \\
        \\-- Test __mod metamethod
        \\local obj_modded = obj % 3
        \\assert(#obj_modded == 2) -- 8 % 3
        \\assert(tostring(obj_modded) == "test_object")
        \\
        \\-- Test __pow metamethod
        \\local obj_powered = obj ^ 2
        \\assert(#obj_powered == 64) -- 8 ^ 2
        \\assert(tostring(obj_powered) == "test_object")
        \\
        \\-- Test __unm metamethod
        \\local obj_negated = -obj
        \\assert(#obj_negated == -8) -- -8
        \\assert(tostring(obj_negated) == "test_object")
        \\
        \\-- Test comparison metamethods
        \\local obj_small = TestUserDataWithMetaMethods.new(5, "small")
        \\local obj_big = TestUserDataWithMetaMethods.new(10, "big")
        \\assert(obj == obj) -- __eq: same object
        \\assert(obj_small ~= obj_big) -- __eq: different objects
        \\assert(obj_small < obj_big) -- __lt: 5 < 10
        \\assert(obj_big > obj_small) -- __lt: 10 > 5 (uses __lt)
        \\assert(obj_small <= obj_big) -- __le: 5 <= 10
        \\assert(obj_small <= obj_small) -- __le: 5 <= 5
        \\
        \\-- Test __concat metamethod
        \\local result = obj .. "suffix"
        \\assert(result == "test_object_suffix") -- __concat
        \\
        \\-- Test multiple objects
        \\local obj2 = TestUserDataWithMetaMethods.new(10, "second")
        \\assert(#obj2 == 10)
        \\assert(tostring(obj2) == "second")
        \\assert(#obj == 8) -- first unchanged
        \\assert(tostring(obj) == "test_object") -- first unchanged
    ;

    try lua.eval(test_script, .{}, void);

    try expectEq(lua.top(), 0);
}
