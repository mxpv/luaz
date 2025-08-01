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

    try lua.globals().set("tupleTable", .{ 42, 3.14, "hello", true });

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

test "Zig function integration" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test calling simple function
    const globals = lua.globals();
    try globals.set("add", testAdd);
    const sum = try lua.eval("return add(10, 20)", .{}, i32);
    try expectEq(sum, 30);

    // Test function returning tuple
    try globals.set("tupleFunc", testTupleReturn);
    try lua.eval("result = tupleFunc(15, 3.5)", .{}, void);
    try expectEq(try lua.eval("return result[1]", .{}, i32), 30); // 15 * 2
    try expectEq(try lua.eval("return result[2]", .{}, f32), 7.0); // 3.5 * 2.0
    try expect(try lua.eval("return result[3]", .{}, bool)); // 15 > 10 = true

    // Test string arguments
    try globals.set("strlen", testStringArg);
    const len = try lua.eval("return strlen('hello')", .{}, i32);
    try expectEq(len, 5);

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
