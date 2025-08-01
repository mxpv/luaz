comptime {
    _ = @import("compile.zig");
    _ = @import("lib.zig");
    _ = @import("state.zig");
}

const std = @import("std");
const Lua = @import("lib.zig").Lua;
const Error = @import("lib.zig").Error;
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

    _ = try lua.eval(
        \\function add(a, b) return a + b end
    , .{}, void);

    const globals = lua.globals();

    const result = try globals.call("add", .{ 10, 20 }, i32);
    try expectEq(result, 30);
    try expectEq(lua.top(), 0);
}

test "function call from global namespace" {
    const lua = try Lua.init(&std.testing.allocator);
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
