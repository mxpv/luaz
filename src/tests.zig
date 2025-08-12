comptime {
    _ = @import("Compiler.zig");
    _ = @import("Lua.zig");
    _ = @import("State.zig");
}

const std = @import("std");
const luaz = @import("lib.zig");
const Lua = luaz.Lua;
const Debug = luaz.Debug;

const Error = luaz.Lua.Error;
const State = @import("State.zig");

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
    const new_value_result = try lua.eval("return newValue", .{}, i32);
    try expectEq(new_value_result.ok, 123);
    const new_flag_result = try lua.eval("return newFlag", .{}, bool);
    try expectEq(new_flag_result.ok, false);

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
    const elem1 = try lua.eval("return tupleTable[1]", .{}, i32);
    try expectEq(elem1.ok, 42);
    const elem2 = try lua.eval("return tupleTable[2]", .{}, f32);
    try expectEq(elem2.ok, 3.14);
    const elem4 = try lua.eval("return tupleTable[4]", .{}, bool);
    try expect(elem4.ok.?);

    // Verify tuple table length
    const length = try lua.eval("return #tupleTable", .{}, i32);
    try expectEq(length.ok, 4);
}

test "eval function" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test basic eval
    const result = try lua.eval("return 2 + 3", .{}, i32);
    try expectEq(result.ok, 5);

    // Test eval with void return
    const void_result = try lua.eval("x = 42", .{}, void);
    try expectEq(void_result, Lua.Result(void){ .ok = {} });
    const globals = lua.globals();
    try expectEq(try globals.get("x", i32), 42);

    // Test eval with tuple return
    const tuple_result = try lua.eval("return 10, 2.5, false", .{}, struct { i32, f64, bool });
    const tuple = tuple_result.ok;
    try expectEq(tuple.?[0], 10);
    try expectEq(tuple.?[1], 2.5);
    try expect(!tuple.?[2]);

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

fn testStructReturn(x: i32, y: i32) struct { x: i32, y: i32, sum: i32 } {
    return .{ .x = x, .y = y, .sum = x + y };
}

fn testArrayReturn(n: i32) [3]i32 {
    return [_]i32{ n, n * 2, n * 3 };
}

test "Zig function integration" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const globals = lua.globals();

    // Test 1: Simple function with two arguments
    try globals.set("add", testAdd);
    const sum_result = try lua.eval("return add(10, 20)", .{}, i32);
    try expectEq(sum_result.ok, 30);

    // Test 2: Function with no arguments
    try globals.set("noArgs", testNoArgs);
    const result = try lua.eval("return noArgs()", .{}, i32);
    try expectEq(result.ok, 42);

    // Test 3: Function with void return
    try globals.set("voidFunc", testVoidReturn);
    _ = try lua.eval("voidFunc(123)", .{}, void);

    // Test 4: Function with multiple different argument types
    try globals.set("multiArgs", testMultipleArgs);
    const multi_result = try lua.eval("return multiArgs(5, 2.5, true)", .{}, f32);
    try expectEq(multi_result.ok, 8.5); // 5 + 2.5 + 1.0

    // Test 5: Function with string arguments
    try globals.set("strlen", testStringArg);
    const len = try lua.eval("return strlen('hello')", .{}, i32);
    try expectEq(len.ok, 5);

    // Test 6: Function returning optional (some value)
    try globals.set("optionalFunc", testOptionalReturn);
    const opt_some = try lua.eval("return optionalFunc(10)", .{}, ?i32);
    try expectEq(opt_some.ok, 20);

    // Test 7: Function returning optional (null value)
    // Note: When Zig function returns null, it becomes nil in Lua,
    // and we need to handle it appropriately when calling from Lua
    _ = try lua.eval("result = optionalFunc(-5)", .{}, void);
    const is_nil_result = try lua.eval("return result == nil", .{}, bool);
    try expect(is_nil_result.ok.?);

    // Test 8: Function returning tuple (multiple separate values)
    try globals.set("tupleFunc", testTupleReturn);
    const tuple_result = try lua.eval("return tupleFunc(15, 3.5)", .{}, struct { i32, f32, bool });
    try expectEq(tuple_result.ok.?[0], 30); // 15 * 2
    try expectEq(tuple_result.ok.?[1], 7.0); // 3.5 * 2.0
    try expect(tuple_result.ok.?[2]); // 15 > 10 = true

    // Test 9: Function with mixed types returning tuple
    try globals.set("mixedFunc", testMixedTypes);
    const mixed_result = try lua.eval("return mixedFunc(10, 'test', false)", .{}, struct { i32, []const u8, bool });
    try expectEq(mixed_result.ok.?[0], 11); // 10 + 1
    try expect(std.mem.eql(u8, mixed_result.ok.?[1], "test"));
    try expect(mixed_result.ok.?[2]); // !false = true

    // Test 10: Function returning struct (should create Lua table)
    try globals.set("structFunc", testStructReturn);
    const struct_x = try lua.eval("return structFunc(5, 7).x", .{}, i32);
    try expectEq(struct_x.ok, 5);
    const struct_y = try lua.eval("return structFunc(5, 7).y", .{}, i32);
    try expectEq(struct_y.ok, 7);
    const struct_sum = try lua.eval("return structFunc(5, 7).sum", .{}, i32);
    try expectEq(struct_sum.ok, 12);

    // Test 11: Function returning array (should create Lua table with integer indices)
    try globals.set("arrayFunc", testArrayReturn);
    const array_1 = try lua.eval("return arrayFunc(10)[1]", .{}, i32); // Lua is 1-indexed
    try expectEq(array_1.ok, 10);
    const array_2 = try lua.eval("return arrayFunc(10)[2]", .{}, i32);
    try expectEq(array_2.ok, 20);
    const array_3 = try lua.eval("return arrayFunc(10)[3]", .{}, i32);
    try expectEq(array_3.ok, 30);

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
    try expectEq(result.ok, 30);

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
    try expectEq(result.ok, 40);

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
        try expectEq(result.ok, 42);
        try expectEq(lua.top(), 0);
    }
}

test "table func compile" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    if (lua.enable_codegen()) {
        _ = try lua.eval("function square(x) return x * x end", .{}, void);

        try lua.globals().compile("square");

        const result1 = try lua.eval("return square(5)", .{}, i32);
        try expectEq(result1.ok, 25);
        const result2 = try lua.eval("return square(10)", .{}, i32);
        try expectEq(result2.ok, 100);
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
    _ = try lua.eval(test_script, .{}, void);

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
        _ = try lua.eval("local obj1 = TestUserDataWithDeinit.new()", .{}, void);
        _ = try lua.eval("local obj2 = TestUserDataWithDeinit.new()", .{}, void);

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

    try expectEq(result.ok, 42);
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
    try expectEq(result.ok, 42);

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

    try expectEq(ptr_result.ok, 84); // 42 * 2

    // Test value userdata parameter (TestUserData)
    const val_result = try lua.eval(
        \\local counter = TestUserData.new(42, "test")
        \\return processVal(counter)
    , .{}, i32);

    try expectEq(val_result.ok, 142); // 42 + 100

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

    _ = try lua.eval(test_script, .{}, void);

    try expectEq(lua.top(), 0);
}

test "Value enum all cases" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();
    lua.openLibs();

    const globals = lua.globals();
    var data: i32 = 123;
    const ptr: *anyopaque = @ptrCast(&data);

    // Test basic Value variants through round-trip storage
    const basic_cases = [_]struct { name: []const u8, value: Lua.Value }{
        .{ .name = "nil", .value = .nil },
        .{ .name = "bool", .value = .{ .boolean = true } },
        .{ .name = "num", .value = .{ .number = 42.5 } },
        .{ .name = "str", .value = .{ .string = "hello" } },
    };

    inline for (basic_cases) |case| {
        try globals.set(case.name, case.value);
        const back = try globals.get(case.name, Lua.Value);
        try expect(back != null);
        try expect(std.meta.activeTag(back.?) == std.meta.activeTag(case.value));
    }

    // Test lightuserdata
    try globals.set("light", Lua.Value{ .lightuserdata = ptr });
    const light_back = try globals.get("light", Lua.Value);
    try expect(light_back.? == .lightuserdata);

    // Test userdata (create proper userdata with reference)
    _ = lua.state.newUserdata(@sizeOf(i32));
    const userdata_ref = Lua.Ref.init(lua, -1);
    lua.state.pop(1); // Remove from stack since we have a reference
    defer userdata_ref.deinit();

    try globals.set("user", Lua.Value{ .userdata = userdata_ref });
    const user_back = try globals.get("user", Lua.Value);
    try expect(user_back.? == .userdata);
    defer user_back.?.deinit();

    // Test table
    const table = lua.createTable(.{});
    try table.set("key", 999);
    try globals.set("table", Lua.Value{ .table = table });
    const table_back = try globals.get("table", Lua.Value);
    try expect(table_back.? == .table);
    defer table_back.?.deinit();
    try expectEq(try table_back.?.table.get("key", i32), 999);

    // Test function
    const testFn = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;
    try globals.set("fn", testFn);
    const func_back = try globals.get("fn", Lua.Value);
    try expect(func_back.? == .function);
    defer func_back.?.deinit();
    const call_result = try func_back.?.function.call(.{5}, i32);
    try expectEq(call_result.ok, 10);

    // Test deinit and Lua eval
    var test_val = Lua.Value{ .number = 1.0 };
    test_val.deinit();
    const from_lua = try lua.eval("return type({})", .{}, Lua.Value);
    try expect(from_lua.ok.? == .string);

    try expectEq(lua.top(), 0);
}

// Global counters for tracking metamethod calls
var index_call_count: u32 = 0;
var newindex_call_count: u32 = 0;

const TestUserDataWithIndexing = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub fn init() TestUserDataWithIndexing {
        return TestUserDataWithIndexing{};
    }

    pub fn __index(self: TestUserDataWithIndexing, key: i32) Lua.Value {
        index_call_count += 1;
        return switch (key) {
            1 => Lua.Value{ .number = @floatFromInt(self.x) },
            2 => Lua.Value{ .number = @floatFromInt(self.y) },
            else => Lua.Value.nil,
        };
    }

    pub fn __newindex(self: *TestUserDataWithIndexing, key: i32, value: f64) void {
        newindex_call_count += 1;
        switch (key) {
            1 => self.x = @intFromFloat(value),
            2 => self.y = @intFromFloat(value),
            else => {},
        }
    }
};

test "userdata with __index and __newindex metamethods" {
    // Reset call counters
    index_call_count = 0;
    newindex_call_count = 0;

    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.state.openLibs();
    try lua.registerUserData(TestUserDataWithIndexing);

    const test_script =
        \\local obj = TestUserDataWithIndexing.new()
        \\
        \\-- Test __newindex - setting values (2 calls to __newindex)
        \\obj[1] = 42
        \\obj[2] = 100
        \\
        \\-- Test __index - getting values (3 calls to __index)
        \\assert(obj[1] == 42)
        \\assert(obj[2] == 100)
        \\assert(obj[999] == nil)
        \\
        \\-- Test overwriting values (1 call to __newindex, 1 call to __index)
        \\obj[1] = 55
        \\assert(obj[1] == 55)
    ;

    _ = try lua.eval(test_script, .{}, void);

    // Validate expected number of calls:
    // __index: 3 gets + 1 final assertion = 4 total
    // __newindex: 2 initial sets + 1 overwrite = 3 total
    try expectEq(index_call_count, 4);
    try expectEq(newindex_call_count, 3);
    try expectEq(lua.top(), 0);
}

test "table canonical iterator" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const table = lua.createTable(.{});
    defer table.deinit();

    // Add various types of entries
    try table.set("name", "Alice");
    try table.set("age", 30);
    try table.set(1, "first");
    try table.set(2, "second");

    // Test canonical Zig iterator pattern
    var count: i32 = 0;
    var found_name = false;
    var found_age = false;
    var found_first = false;
    var found_second = false;

    var iterator = table.iterator();
    while (try iterator.next()) |entry| {
        count += 1;

        // Check what we found using helper methods
        if (entry.key.asString()) |s| {
            if (std.mem.eql(u8, s, "name")) {
                found_name = true;
                if (entry.value.asString()) |v| {
                    try expect(std.mem.eql(u8, v, "Alice"));
                } else {
                    try expect(false);
                }
            } else if (std.mem.eql(u8, s, "age")) {
                found_age = true;
                if (entry.value.asNumber()) |v| {
                    try expectEq(v, 30);
                } else {
                    try expect(false);
                }
            }
        } else if (entry.key.asNumber()) |n| {
            if (n == 1) {
                found_first = true;
                if (entry.value.asString()) |v| {
                    try expect(std.mem.eql(u8, v, "first"));
                } else {
                    try expect(false);
                }
            } else if (n == 2) {
                found_second = true;
                if (entry.value.asString()) |v| {
                    try expect(std.mem.eql(u8, v, "second"));
                } else {
                    try expect(false);
                }
            }
        }
    }

    try expectEq(count, 4);
    try expect(found_name);
    try expect(found_age);
    try expect(found_first);
    try expect(found_second);

    // Test iterator with empty table
    const empty_table = lua.createTable(.{});
    defer empty_table.deinit();

    var empty_iterator = empty_table.iterator();
    var empty_count: i32 = 0;
    while (try empty_iterator.next()) |_| {
        empty_count += 1;
    }
    try expectEq(empty_count, 0);
}

// Test error types and functions for error handling tests
const TestError = error{ InvalidInput, NotFound, OutOfBounds };

fn divide(a: f64, b: f64) TestError!f64 {
    if (b == 0) return error.InvalidInput;
    return a / b;
}

fn findUser(id: i32) TestError!struct { []const u8, i32 } {
    if (id == 1) return .{ "Alice", 30 };
    return error.NotFound;
}

test "error handling in wrapped functions" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();
    lua.openLibs();

    const globals = lua.globals();
    try globals.set("divide", divide);
    try globals.set("findUser", findUser);

    // Test success cases
    const divide_result = try lua.eval("return divide(10, 2)", .{}, f64);
    try expectEq(divide_result.ok, 5.0);
    const user = try lua.eval("return findUser(1)", .{}, struct { []const u8, i32 });
    try expect(std.mem.eql(u8, user.ok.?.@"0", "Alice"));
    try expectEq(user.ok.?.@"1", 30);

    // Test error cases
    try expect(lua.eval("return divide(10, 0)", .{}, f64) == error.Runtime);
    try expect(lua.eval("return findUser(999)", .{}, struct { []const u8, i32 }) == error.Runtime);

    // Test error messages via pcall
    const err1 = try lua.eval("local ok, err = pcall(divide, 10, 0); return err", .{}, []const u8);
    try expect(std.mem.eql(u8, err1.ok.?, "InvalidInput"));

    const err2 = try lua.eval("local ok, err = pcall(findUser, 999); return err", .{}, []const u8);
    try expect(std.mem.eql(u8, err2.ok.?, "NotFound"));

    // Test userdata method with error
    const Counter = struct {
        count: i32,

        pub fn init() @This() {
            return .{ .count = 0 };
        }

        pub fn increment(self: *@This(), amount: i32) TestError!void {
            if (amount < 0) return error.InvalidInput;
            self.count += amount;
        }

        pub fn getValue(self: *const @This()) i32 {
            return self.count;
        }
    };

    try lua.registerUserData(Counter);

    // Test successful method call
    _ = try lua.eval("local c = Counter.new(); c:increment(5); return c:getValue()", .{}, i32);

    // Test error in userdata method
    try expect(lua.eval("local c = Counter.new(); c:increment(-1)", .{}, void) == error.Runtime);

    // Test error message from userdata method
    const err3 = try lua.eval("local c = Counter.new(); local ok, err = pcall(c.increment, c, -1); return err", .{}, []const u8);
    try expect(std.mem.eql(u8, err3.ok.?, "InvalidInput"));
}

const stack = @import("stack.zig");

test "thread creation and basic operations" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.openLibs();

    // Create a new thread - now just returns another Lua object
    const thread_lua = lua.createThread();

    // Basic test: thread can execute simple Lua code
    const result = try thread_lua.eval("return 42", .{}, i32);
    try expectEq(result.ok, 42);

    // Thread shares global environment with parent
    _ = try lua.eval("test_value = 123", .{}, void);
    const shared = try thread_lua.eval("return test_value", .{}, i32);
    try expectEq(shared.ok, 123);

    // Test thread API methods are available
    try expect(thread_lua.isYieldable()); // Threads are yieldable when created
    try expect(thread_lua.isReset()); // Threads start in reset state
}

test "coroutine yield and resume" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.openLibs();

    // Create a coroutine function in global environment
    _ = try lua.eval(
        \\function yielder()
        \\    coroutine.yield(1)
        \\    coroutine.yield(2)
        \\    return 3
        \\end
    , .{}, void);

    // Create thread - it shares the global environment
    const thread = lua.createThread();

    // Load function onto thread stack and start coroutine
    const func = try thread.globals().get("yielder", Lua.Function);
    defer func.?.deinit();

    // First resume - should yield 1
    const result1 = try func.?.call(.{}, i32);
    try expectEq(result1.yield, 1);

    // Second resume - should yield 2
    const result2 = try func.?.call(.{}, i32);
    try expectEq(result2.yield, 2);

    // Third resume - should return 3 and finish
    const result3 = try func.?.call(.{}, i32);
    try expectEq(result3.ok, 3);
}

test "coroutine with arguments on yield" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.openLibs();

    // Create a coroutine that processes arguments
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

    // Create thread and load the coroutine
    const thread = lua.createThread();

    const func = try thread.globals().get("accumulator", Lua.Function);
    defer func.?.deinit();

    // Start the coroutine - yields 0
    const result1_value = try func.?.call(.{}, i32);
    try expectEq(result1_value.yield, 0);

    // Continue the coroutine with value 5
    const result2_value = try func.?.call(.{5}, i32);
    try expectEq(result2_value.yield, 5);

    // Continue the coroutine with value 10
    const result3_value = try func.?.call(.{10}, i32);
    try expectEq(result3_value.yield, 15);

    // Finish the coroutine with nil
    const result4_value = try func.?.call(.{@as(?i32, null)}, i32);
    try expectEq(result4_value.ok, 15);
}

test "thread data via globals" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const thread = lua.createThread();

    // Test that threads can share data through globals
    try lua.globals().set("shared_data", 42);
    const retrieved = try thread.globals().get("shared_data", i32);
    try expectEq(retrieved, 42);

    // Test thread can modify shared data
    try thread.globals().set("thread_value", 100);
    const from_main = try lua.globals().get("thread_value", i32);
    try expectEq(from_main, 100);
}

test "thread API methods" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const thread = lua.createThread();

    // Test thread status and state methods
    try expectEq(thread.status(), .done); // Empty threads are done
    try expect(thread.isReset()); // Threads start reset
    try expect(thread.isYieldable()); // Threads are yieldable

    // Test thread-specific data storage
    try expectEq(thread.getData(), null); // Initially no data

    var test_data: i32 = 123;
    thread.setData(&test_data);
    const retrieved_data = thread.getData();
    try expect(retrieved_data != null);
    const value = @as(*i32, @ptrCast(@alignCast(retrieved_data.?))).*;
    try expectEq(value, 123);

    // Test reset
    thread.reset();
    try expect(thread.isReset());
    // Note: Thread data persists across reset - it's not cleared by resetThread()
}

test "isThread method" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Main Lua state should not be a thread
    try expect(!lua.isThread());

    // Create a thread - it should be identified as a thread
    const thread_lua = lua.createThread();
    try expect(thread_lua.isThread());

    // Multiple threads should all be identified as threads
    const thread2_lua = lua.createThread();
    try expect(thread2_lua.isThread());

    // Original main state should still not be a thread
    try expect(!lua.isThread());
}

test "simple thread function execution" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.openLibs();

    // Create a simple function
    _ = try lua.eval(
        \\function simple()
        \\    return 42
        \\end
    , .{}, void);

    const thread_lua = lua.createThread();

    // Load and run function in thread
    const func = try thread_lua.globals().get("simple", Lua.Function);
    defer func.?.deinit();

    const result = try func.?.call(.{}, i32);
    try expectEq(result.ok, 42);
}

test "coroutine error handling" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.openLibs();

    // Create a coroutine that errors
    _ = try lua.eval(
        \\function error_coro()
        \\    error("intentional error")
        \\end
    , .{}, void);

    const thread_lua = lua.createThread();

    const func = try thread_lua.globals().get("error_coro", Lua.Function);
    defer func.?.deinit();

    // Resume should return error
    const error_result = func.?.call(.{}, void);
    try std.testing.expectError(error.Runtime, error_result);
}

test "resume from main thread should return error" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Verify this is the main thread
    try expect(!lua.isThread());

    // Create a simple function (not a coroutine)
    _ = try lua.eval(
        \\function test_func()
        \\    return 42
        \\end
    , .{}, void);

    // In main thread, functions are called with pcall semantics, not resume
    // This is tested implicitly - Function.call() automatically detects thread context
    const func = try lua.globals().get("test_func", Lua.Function);
    defer func.?.deinit();

    // This will use pcall since we're in main thread
    const result = try func.?.call(.{}, i32);
    try expectEq(result.ok, 42);
}

// Sandbox-related tests

test "sandbox" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();
    lua.openLibs();

    // Before sandbox: can modify built-in library
    _ = try lua.eval("math.huge = 'hacked'", .{}, void);
    const hacked_value = try lua.eval("return math.huge", .{}, Lua.Value);
    defer hacked_value.ok.?.deinit();
    try expect(std.mem.eql(u8, hacked_value.ok.?.asString().?, "hacked"));

    // Apply sandbox
    lua.sandbox();

    // After sandbox: cannot modify built-in library (throws error)
    const result = lua.eval("math.huge = 'blocked'", .{}, void);
    try std.testing.expectError(Lua.Error.Runtime, result);

    // Verify the original value is still there
    const protected_value = try lua.eval("return math.huge", .{}, Lua.Value);
    defer protected_value.ok.?.deinit();
    try expect(std.mem.eql(u8, protected_value.ok.?.asString().?, "hacked")); // Still the old value
}

test "table readonly" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const table = lua.createTable(.{});
    defer table.deinit();

    try table.set("key", "value");
    try lua.globals().set("t", table);

    _ = try lua.eval("t.before = 'works'", .{}, void);
    try expect(try table.get("before", []const u8) != null);

    try table.setReadonly(true);

    _ = lua.eval("t.after = 'blocked'", .{}, void) catch {};
    try expect(try table.get("after", ?i32) == null);
}

test "table clear" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const table = lua.createTable(.{});
    defer table.deinit();

    // Add some entries
    try table.set("name", "Alice");
    try table.set(1, 42);
    try table.set("data", true);

    // Clear all entries
    try table.clear();

    // Table is now empty
    const name = try table.get("name", []const u8);
    try expect(name == null);
}

test "table clone" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const original = lua.createTable(.{});
    defer original.deinit();
    try original.set("name", "Alice");

    const cloned = try original.clone();
    defer cloned.deinit();

    // Clone has same values
    const name = try cloned.get("name", []const u8);
    try expect(std.mem.eql(u8, name.?, "Alice"));
}

test "function clone" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    _ = try lua.eval("function add(a, b) return a + b end", .{}, void);

    const func = try lua.globals().get("add", Lua.Function);
    defer func.?.deinit();

    const cloned = try func.?.clone();
    defer cloned.deinit();

    // Both functions work the same
    const result1 = try func.?.call(.{ 10, 20 }, i32);
    const result2 = try cloned.call(.{ 10, 20 }, i32);
    try expect(result1.ok.? == 30);
    try expect(result2.ok.? == 30);
}

fn closureAdd5(upv: Lua.Upvalues(i32), x: i32) i32 {
    return x + upv.value;
}

fn closureTransform(upv: Lua.Upvalues(struct { f32, f32 }), x: f32) f32 {
    return x * upv.value[0] + upv.value[1];
}

fn closureOptAdd(upv: Lua.Upvalues(i32), x: i32, y: ?i32) i32 {
    const thresh = upv.value;
    return if (x > thresh) x + (y orelse 0) else x;
}

fn closureMultiply(upv: Lua.Upvalues(Lua.Table), x: i32) !i32 {
    const cfg = upv.value;
    const m = try cfg.get("mult", i32) orelse 1;
    return x * m;
}

fn closureConstant(upv: Lua.Upvalues(i32)) i32 {
    return upv.value;
}

fn closureSumAll(upv: Lua.Upvalues(i32), a: ?i32, b: ?i32) i32 {
    return upv.value + (a orelse 0) + (b orelse 0);
}

fn closureSingle(upv: Lua.Upvalues(i32), x: i32) i32 {
    return x + upv.value;
}

const ClosureCounter = struct {
    count: i32,

    fn increment(upv: Lua.Upvalues(*ClosureCounter), amount: i32) i32 {
        upv.value.count += amount;
        return upv.value.count;
    }

    fn getValue(upv: Lua.Upvalues(*ClosureCounter)) i32 {
        return upv.value.count;
    }
};

test "table setClosure" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const table = lua.createTable(.{});
    defer table.deinit();

    // Single upvalue
    try table.setClosure("add5", 5, closureAdd5);

    // Multiple upvalues
    try table.setClosure("transform", .{ 2.0, 10.0 }, closureTransform);

    // Optional parameters
    try table.setClosure("optAdd", 10, closureOptAdd);

    // Table reference upvalue
    const config = lua.createTable(.{});
    defer config.deinit();
    try config.set("mult", @as(i32, 3));
    try table.setClosure("multiply", config, closureMultiply);

    // No additional parameters
    try table.setClosure("const", 42, closureConstant);

    // Multiple optionals
    try table.setClosure("sum", 100, closureSumAll);

    // Single upvalue (not wrapped in struct)
    try table.setClosure("single", 42, closureSingle);

    try lua.globals().set("f", table);
    try lua.globals().set("config", config);

    // Test all closure types
    const add5_result = try lua.eval("return f.add5(10)", .{}, i32);
    try expect(add5_result.ok == 15);
    const transform_result = try lua.eval("return f.transform(5)", .{}, f32);
    try expect(@abs(transform_result.ok.? - 20.0) < 0.001);
    const optAdd1_result = try lua.eval("return f.optAdd(15, 5)", .{}, i32);
    try expect(optAdd1_result.ok == 20);
    const optAdd2_result = try lua.eval("return f.optAdd(15)", .{}, i32);
    try expect(optAdd2_result.ok == 15);
    const optAdd3_result = try lua.eval("return f.optAdd(5, 10)", .{}, i32);
    try expect(optAdd3_result.ok == 5);
    const multiply1_result = try lua.eval("return f.multiply(5)", .{}, i32);
    try expect(multiply1_result.ok == 15);
    const const_result = try lua.eval("return f.const()", .{}, i32);
    try expect(const_result.ok == 42);
    const sum1_result = try lua.eval("return f.sum()", .{}, i32);
    try expect(sum1_result.ok == 100);
    const sum2_result = try lua.eval("return f.sum(1, 2)", .{}, i32);
    try expect(sum2_result.ok == 103);
    const single_result = try lua.eval("return f.single(8)", .{}, i32);
    try expect(single_result.ok == 50);

    // Test config modification
    _ = try lua.eval("config.mult = 7", .{}, void);
    const multiply2_result = try lua.eval("return f.multiply(5)", .{}, i32);
    try expect(multiply2_result.ok == 35);
}

test "setClosure with pointer receiver" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const table = lua.createTable(.{});
    defer table.deinit();

    // Create a counter instance
    var counter = ClosureCounter{ .count = 10 };

    // Register methods with *Self receivers as closures (direct pointer)
    // Note: User is responsible for ensuring the pointer remains valid for the lifetime of the closure
    try table.setClosure("increment", &counter, ClosureCounter.increment);
    try table.setClosure("getValue", &counter, ClosureCounter.getValue);

    try lua.globals().set("counter", table);

    // Test initial value
    const getValue1_result = try lua.eval("return counter.getValue()", .{}, i32);
    try expect(getValue1_result.ok == 10);

    // Test increment with mutable *Self
    const increment1_result = try lua.eval("return counter.increment(5)", .{}, i32);
    try expect(increment1_result.ok == 15);
    const getValue2_result = try lua.eval("return counter.getValue()", .{}, i32);
    try expect(getValue2_result.ok == 15);

    // Test multiple increments
    const increment2_result = try lua.eval("return counter.increment(3)", .{}, i32);
    try expect(increment2_result.ok == 18);
    const increment3_result = try lua.eval("return counter.increment(2)", .{}, i32);
    try expect(increment3_result.ok == 20);
    const getValue3_result = try lua.eval("return counter.getValue()", .{}, i32);
    try expect(getValue3_result.ok == 20);
}

test "metatable with closure function and table attachment" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.state.openLibs(); // Need standard libraries

    // Step 1: Create empty metatable (not from struct type)
    const metatable = lua.createTable(.{});
    defer metatable.deinit();

    // Step 2: Set function with upvalue (i32 = 4) and one parameter
    // The function returns sum of upvalue + passed parameter
    const AddFunc = struct {
        fn add(upv: Lua.Upvalues(i32), param: i32) i32 {
            return upv.value + param;
        }
    };

    try metatable.setClosure("compute", 4, AddFunc.add);

    // Set __index to metatable itself for method lookup
    try metatable.set("__index", metatable);

    // Step 3: Create empty table
    const empty_table = lua.createTable(.{});
    defer empty_table.deinit();

    // Step 4: Attach metatable to empty table
    try empty_table.setMetaTable(metatable);

    // Step 5: Set this table as global
    try lua.globals().set("myTable", empty_table);

    // Step 6: Run lua script to call static function with param = 6 from empty table
    const result = try lua.eval("return myTable.compute(6)", .{}, i32);

    // Step 7: Verify returned result = 10 (4 + 6)
    try expectEq(result.ok, 10);

    try expectEq(lua.top(), 0);
}

test "varargs basic functionality" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const TestFuncs = struct {
        fn countArgs(args: Lua.Varargs) i32 {
            return @intCast(args.len());
        }
    };

    const globals = lua.globals();
    try globals.set("countArgs", TestFuncs.countArgs);

    // Test count
    const count_result = try lua.eval("return countArgs(1, 2, 3, 4)", .{}, i32);
    try expectEq(count_result.ok, 4);

    try expectEq(lua.top(), 0);
}

test "varargs at method only" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const TestFuncs = struct {
        fn getAt(args: Lua.Varargs) f64 {
            return args.at(f64, 1) orelse 0;
        }
    };

    const globals = lua.globals();
    try globals.set("getAt", TestFuncs.getAt);

    // Test at() method only
    const at_result = try lua.eval("return getAt(1, 42.5, 3)", .{}, f64);
    try expectEq(at_result.ok, 42.5);

    try expectEq(lua.top(), 0);
}

test "varargs next method only" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const TestFuncs = struct {
        fn getFirst(args: Lua.Varargs) f64 {
            var iter = args;
            return iter.next(f64) orelse 0;
        }
    };

    const globals = lua.globals();
    try globals.set("getFirst", TestFuncs.getFirst);

    // Test next() method only
    const result = try lua.eval("return getFirst(42.5, 2, 3)", .{}, f64);
    try expectEq(result.ok, 42.5);

    try expectEq(lua.top(), 0);
}

test "varargs iterator reset" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const TestFuncs = struct {
        fn doubleIterate(args: Lua.Varargs) i32 {
            var mutable_args = args;
            var first_sum: i32 = 0;
            var second_sum: i32 = 0;

            // First iteration
            while (mutable_args.next(i32)) |value| {
                first_sum += value;
            }

            // Reset and iterate again
            mutable_args.reset();
            while (mutable_args.next(i32)) |value| {
                second_sum += value;
            }

            return first_sum + second_sum;
        }
    };

    const globals = lua.globals();
    try globals.set("doubleIterate", TestFuncs.doubleIterate);

    // Test reset functionality - should sum twice
    const result = try lua.eval("return doubleIterate(5, 10, 15)", .{}, i32);
    try expectEq(result.ok, 60); // (5+10+15) * 2 = 60
    try expectEq(lua.top(), 0);
}

test "varargs error handling" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const TestFuncs = struct {
        fn typeCheck(args: Lua.Varargs) void {
            var iter = args;
            _ = iter.next([]const u8) orelse {
                iter.raiseError("expected string");
            };
        }
    };

    const globals = lua.globals();
    try globals.set("typeCheck", TestFuncs.typeCheck);

    try expect(lua.eval("typeCheck({})", .{}, void) == error.Runtime);
    try expectEq(lua.top(), 0);
}

test "StrBuf basic functionality" {
    var lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test basic StrBuf functionality
    var buf: Lua.StrBuf = undefined;
    buf.init(&lua);
    buf.addString("Hello");
    buf.addChar(' ');
    buf.addString("World");

    const globals = lua.globals();
    try globals.set("message", &buf);
    const result = try globals.get("message", []const u8);
    try expectEq(std.mem.eql(u8, result.?, "Hello World"), true);

    try expectEq(lua.top(), 0);
}

test "StrBuf initialization with size" {
    var lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test initSize method
    var buf: Lua.StrBuf = undefined;
    buf.initSize(&lua, 100);

    buf.addString("Testing ");
    buf.addString("pre-allocated ");
    buf.addString("buffer");

    const globals = lua.globals();
    try globals.set("sized_message", &buf);
    const result = try globals.get("sized_message", []const u8);
    try expectEq(std.mem.eql(u8, result.?, "Testing pre-allocated buffer"), true);

    try expectEq(lua.top(), 0);
}

test "StrBuf add method with various types" {
    var lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    var buf: Lua.StrBuf = undefined;
    buf.init(&lua);

    // Test different numeric types
    try buf.add(@as(i32, 42));
    buf.addChar(',');
    try buf.add(@as(f64, 3.14));
    buf.addChar(',');

    // Test boolean
    try buf.add(true);
    buf.addChar(',');
    try buf.add(false);
    buf.addChar(',');

    // Test optional/nil
    try buf.add(@as(?i32, null));
    buf.addChar(',');
    try buf.add(@as(?i32, 123));

    const globals = lua.globals();
    try globals.set("values", &buf);
    const result = try globals.get("values", []const u8);
    try expectEq(std.mem.eql(u8, result.?, "42,3.14,true,false,nil,123"), true);

    try expectEq(lua.top(), 0);
}

test "StrBuf with string values" {
    var lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    var buf: Lua.StrBuf = undefined;
    buf.init(&lua);
    buf.addString("Prefix: ");
    try buf.add("Hello");
    buf.addChar(' ');
    try buf.add(@as([]const u8, "from Zig!"));

    const globals = lua.globals();
    try globals.set("greeting", &buf);
    const result = try globals.get("greeting", []const u8);
    try expectEq(std.mem.eql(u8, result.?, "Prefix: Hello from Zig!"), true);

    try expectEq(lua.top(), 0);
}

test "StrBuf integration with Table operations" {
    var lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const table = lua.createTable(.{ .arr = 0, .rec = 5 });
    defer table.deinit();

    // Create multiple StrBuf instances for different table entries
    var buf1: Lua.StrBuf = undefined;
    buf1.init(&lua);
    buf1.addString("Item ");
    try buf1.add(@as(i32, 1));
    try table.set("first", &buf1);

    var buf2: Lua.StrBuf = undefined;
    buf2.init(&lua);
    buf2.addString("Value: ");
    try buf2.add(@as(f64, 42.5));
    try table.set("second", &buf2);

    var buf3: Lua.StrBuf = undefined;
    buf3.init(&lua);
    try buf3.add(true);
    buf3.addString(" is ");
    try buf3.add(false);
    try table.set("third", &buf3);

    // Verify values through table get
    const val1 = try table.get("first", []const u8);
    try expectEq(std.mem.eql(u8, val1.?, "Item 1"), true);

    const val2 = try table.get("second", []const u8);
    try expectEq(std.mem.eql(u8, val2.?, "Value: 42.5"), true);

    const val3 = try table.get("third", []const u8);
    try expectEq(std.mem.eql(u8, val3.?, "true is false"), true);

    try expectEq(lua.top(), 0);
}

// Define a Zig function that builds and returns StrBuf by pointer
fn makeMsg(upv: Lua.Upvalues(*Lua), name: []const u8, value: i32) !Lua.StrBuf {
    const l = upv.value;
    var buf: Lua.StrBuf = undefined;
    buf.init(l);
    buf.addString("Hello ");
    buf.addLString(name);
    buf.addString(", value is ");
    try buf.add(value);

    return buf;
}

test "StrBuf returned from Zig functions" {
    var lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test if function is registered at all
    try lua.globals().setClosure("makeMsg", &lua, makeMsg);

    // Check if the function exists
    const funcExists = try lua.eval("return makeMsg ~= nil", .{}, bool);
    try expectEq(funcExists.ok, true);

    // Simple call to see what happens
    const result = try lua.eval("return makeMsg('Alice', 42)", .{}, []const u8);
    const expected = "Hello Alice, value is 42";
    try expectEq(std.mem.startsWith(u8, result.ok.?, expected), true);
}

// Test function that returns StrBuf as part of a tuple
fn makeMsgTuple(upv: Lua.Upvalues(*Lua), name: []const u8, value: i32) !struct { Lua.StrBuf, i32 } {
    const l = upv.value;
    var buf: Lua.StrBuf = undefined;
    buf.init(l);
    buf.addString("Tuple: ");
    buf.addLString(name);
    buf.addString(" = ");
    try buf.add(value);

    return .{ buf, value * 2 };
}

test "StrBuf returned in tuple from Zig functions" {
    var lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Set function that returns a tuple containing StrBuf
    try lua.globals().setClosure("makeTuple", &lua, makeMsgTuple);

    // Check if the function exists
    const funcExists = try lua.eval("return makeTuple ~= nil", .{}, bool);
    try expectEq(funcExists.ok, true);

    // Call function that returns tuple (StrBuf, i32)
    const result = try lua.eval("return makeTuple('test', 21)", .{}, struct { []const u8, i32 });

    const expected_str = "Tuple: test = 21";
    try expectEq(std.mem.startsWith(u8, result.ok.?[0], expected_str), true);
    try expectEq(result.ok.?[1], 42);
}

// Test function that builds a large StrBuf to force dynamic allocation
fn makeLargeMsg(upv: Lua.Upvalues(*Lua), count: i32) !Lua.StrBuf {
    const l = upv.value;
    var buf: Lua.StrBuf = undefined;
    buf.init(l);

    // Build a string longer than LUA_BUFFERSIZE (512 bytes) to force dynamic allocation
    buf.addString("Large message: ");

    // Add enough content to exceed buffer size
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        buf.addString("This is a repeated string to exceed buffer size! ");
        try buf.add(i);
        buf.addString(" ");
    }

    return buf;
}

test "StrBuf with dynamic allocation returned from Zig functions" {
    var lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Set function that creates large StrBuf requiring dynamic allocation
    try lua.globals().setClosure("makeLarge", &lua, makeLargeMsg);

    // Test with enough iterations to exceed 512 bytes
    // Each iteration adds ~50+ bytes, so 15 iterations should exceed 512 bytes
    const result = try lua.eval("return makeLarge(15)", .{}, []const u8);

    // Verify the result starts correctly and is reasonably long
    try expectEq(std.mem.startsWith(u8, result.ok.?, "Large message: This is a repeated string"), true);
    try expectEq(result.ok.?.len > 512, true); // Should be longer than buffer size

    // Verify it contains content from both early and late iterations
    try expectEq(std.mem.indexOf(u8, result.ok.?, "0 ") != null, true); // First iteration
    try expectEq(std.mem.indexOf(u8, result.ok.?, "14 ") != null, true); // Last iteration
}

test "setCallbacks onallocate" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const AllocCallbacks = struct {
        var called: bool = false;

        pub fn onallocate(state: *State, osize: usize, nsize: usize) void {
            _ = state;
            _ = osize;
            _ = nsize;
            called = true;
        }
    };

    AllocCallbacks.called = false;
    lua.setCallbacks(AllocCallbacks{});

    const globals = lua.globals();
    try globals.set("key", "value");

    try expect(AllocCallbacks.called);
}

test "setCallbacks userthread" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const ThreadCallbacks = struct {
        var created: bool = false;

        pub fn userthread(parent: ?*State, thread: *State) void {
            _ = thread;
            _ = parent;
            created = true;
        }
    };

    ThreadCallbacks.created = false;
    lua.setCallbacks(ThreadCallbacks{});

    _ = lua.createThread();
    try expect(ThreadCallbacks.created);
}

test "setCallbacks all callbacks" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const AllCallbacks = struct {
        pub fn interrupt(state: *State, gc_flag: i32) void {
            _ = state;
            _ = gc_flag;
        }

        pub fn panic(state: *State, errcode: i32) void {
            _ = state;
            _ = errcode;
        }

        pub fn userthread(parent: ?*State, thread: *State) void {
            _ = parent;
            _ = thread;
        }

        pub fn useratom(s: []const u8) i16 {
            _ = s;
            return 0;
        }

        pub fn debugbreak(debug: *Lua.Debug, ar: Lua.Debug.Info) void {
            _ = debug;
            _ = ar;
        }

        pub fn debugstep(debug: *Lua.Debug, ar: Lua.Debug.Info) void {
            _ = debug;
            _ = ar;
        }

        pub fn debuginterrupt(debug: *Lua.Debug, ar: Lua.Debug.Info) void {
            _ = debug;
            _ = ar;
        }

        pub fn debugprotectederror(debug: *Lua.Debug) void {
            _ = debug;
        }

        pub fn onallocate(state: *State, osize: usize, nsize: usize) void {
            _ = state;
            _ = osize;
            _ = nsize;
        }
    };

    lua.setCallbacks(AllCallbacks{});

    _ = lua.createThread(); // Should trigger userthread
    const globals = lua.globals();
    try globals.set("test", "value"); // Should trigger onallocate
}

test "setCallbacks instance methods" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const InstanceCallbacks = struct {
        counter: u32 = 0,

        pub fn onallocate(self: *@This(), state: *State, osize: usize, nsize: usize) void {
            _ = state;
            _ = osize;
            _ = nsize;
            self.counter += 1;
        }
    };

    var callbacks = InstanceCallbacks{};
    lua.setCallbacks(&callbacks);

    const globals = lua.globals();
    try globals.set("key", "value");

    try expect(callbacks.counter > 0);
}
