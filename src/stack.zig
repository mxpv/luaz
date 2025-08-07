//! Helper module for manipulating Zig types on the Lua stack.
//!
//! This module provides functions to push, pop, and convert Zig types to and from Lua stack slots.
//! It heavily relies on compile-time reflection to determine how to handle different types.
//!
//! Supported type conversions to Lua:
//! - Primitive types (bool, integers, floats) → corresponding Lua types
//! - Strings (various formats) → Lua strings
//! - Optional types → Lua values or nil
//! - Tuples → pushed as individual values (not tables)
//! - Structs → Lua tables with field names as keys (data fields only, no methods)
//! - Arrays → Lua tables with 1-based integer indices
//! - Slices → Lua tables with 1-based integer indices
//! - Functions → wrapped as callable Lua functions
//! - Vectors → Luau native vector types

const std = @import("std");
const State = @import("state.zig").State;
const Lua = @import("lua.zig").Lua;

/// Counts how many Lua stack slots are needed for the given type.
///
/// This is typically 1 for most types, but there are edge cases:
/// - void requires 0 slots (nothing is pushed)
/// - tuples require a slot for each element
/// - structs and arrays are converted to tables and require 1 slot
pub fn slotCountFor(comptime T: type) i32 {
    if (T == void) {
        return 0;
    }

    const type_info = @typeInfo(T);
    if (type_info == .@"struct" and type_info.@"struct".is_tuple) {
        return @intCast(type_info.@"struct".fields.len);
    }

    // Structs, arrays, and slices are all converted to tables (1 slot)
    // Default to 1 for everything else
    return 1;
}

/// Internal function to push a Zig value onto the Lua stack.
/// Used internally by table operations and other high-level functions.
///
/// Note: For light userdata (pointer types), the caller is responsible for ensuring
/// the pointed-to object remains alive for as long as it is used in Lua. Light userdata
/// does not participate in Lua's garbage collection.
pub fn push(lua: Lua, value: anytype) void {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);

    switch (type_info) {
        .bool => {
            lua.state.pushBoolean(value);
        },
        .int, .comptime_int => {
            lua.state.pushInteger(@intCast(value));
        },
        .float, .comptime_float => {
            lua.state.pushNumber(value);
        },
        .void => {
            // Push nothing.
        },
        .null => {
            lua.state.pushNil();
        },
        .optional => {
            if (value == null) {
                lua.state.pushNil();
            } else {
                push(lua, value.?);
            }
        },
        .@"struct" => {
            // Handle Ref and Table types
            if (T == Lua.Ref or T == Lua.Table or T == Lua.Function) {
                // Push reference to stack
                if (value.getRef()) |index| {
                    if (index != State.GLOBALSINDEX) {
                        _ = lua.state.rawGetI(State.REGISTRYINDEX, index);
                    } else {
                        // Globals table is a special pseudo-index, push it directly
                        lua.state.pushValue(index);
                    }
                } else {
                    lua.state.pushNil();
                }
                return;
            }

            // Handle tuples by pushing each element individually
            if (type_info.@"struct".is_tuple) {
                inline for (0..type_info.@"struct".fields.len) |i| {
                    push(lua, value[i]);
                }
                return;
            }

            // Handle arbitrary structs by converting to Lua table (data fields only)
            lua.state.createTable(0, type_info.@"struct".fields.len);

            // Push struct fields only - exclude all methods since they won't work correctly
            inline for (type_info.@"struct".fields) |field| {
                if (field.is_comptime) continue; // Skip comptime fields

                // Push field name as key
                lua.state.pushString(field.name);
                // Push field value
                push(lua, @field(value, field.name));
                // Set table[field_name] = field_value
                lua.state.setTable(-3);
            }
            return;
        },
        .@"union" => {
            // Handle Value union
            if (T == Lua.Value) {
                switch (value) {
                    .nil => lua.state.pushNil(),
                    .boolean => |b| lua.state.pushBoolean(b),
                    .number => |n| lua.state.pushNumber(n),
                    .string => |s| lua.state.pushLString(s),
                    .table => |t| push(lua, t),
                    .function => |f| push(lua, f),
                    .userdata => |u| push(lua, u), // Push userdata reference
                    .lightuserdata => |u| lua.state.pushLightUserdata(u),
                }
                return;
            }

            @compileError("Cannot push union type " ++ @typeName(T) ++ " to Lua stack");
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
            lua.state.pushVector(vec_array);
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
                            lua.state.pushString(@as([:0]const u8, @ptrCast(value)));
                        } else {
                            // Regular array: *const [N]u8
                            lua.state.pushLString(std.mem.asBytes(value));
                        }
                        return;
                    }

                    // Handle light user data: *T where T is not an array
                    // IMPORTANT: Caller must ensure the pointed-to object remains alive
                    // for as long as it's used in Lua (no garbage collection for light userdata)
                    lua.state.pushLightUserdata(@ptrCast(@constCast(value)));
                    return;
                },
                .many, .slice => {
                    // Handle strings: []const u8, [:0]const u8, [*:0]const u8
                    if (ptr_info.child == u8) {
                        // For slices, check if it's zero-terminated by examining the type
                        if (comptime std.mem.indexOf(u8, @typeName(T), ":0") != null) {
                            // Zero-terminated string: [:0]const u8, [*:0]const u8
                            lua.state.pushString(@as([:0]const u8, @ptrCast(value)));
                        } else {
                            // Regular slice: []const u8
                            lua.state.pushLString(value);
                        }
                        return;
                    }

                    // Handle arbitrary slices by converting to Lua table with integer indices
                    lua.state.createTable(@intCast(value.len), 0);
                    for (value, 0..) |element, i| {
                        // Push element value
                        push(lua, element);
                        // Set table[i+1] = element (Lua arrays are 1-indexed)
                        lua.state.rawSetI(-2, @intCast(i + 1));
                    }
                    return;
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
                    lua.state.pushString(@as([:0]const u8, @ptrCast(&value)));
                } else {
                    // Regular array: [N]u8
                    lua.state.pushLString(&value);
                }
                return;
            }

            // Handle arbitrary arrays by converting to Lua table with integer indices
            lua.state.createTable(array_info.len, 0);
            for (value, 0..) |element, i| {
                // Push element value
                push(lua, element);
                // Set table[i+1] = element (Lua arrays are 1-indexed)
                lua.state.rawSetI(-2, @intCast(i + 1));
            }
            return;
        },
        .@"fn" => {
            if (*const T == @typeInfo(State.CFunction).optional.child) {
                lua.state.pushCFunction(value, @typeName(T));
                return;
            }

            const trampoline = createFunc(lua, value, null);
            lua.state.pushCFunction(trampoline, @typeName(T));
        },
        else => {
            @compileError("Unable to push type " ++ @typeName(T));
        },
    }
}

/// Pushes a function result onto the Lua stack, handling error unions, tuples, and regular values.
/// Returns the number of values pushed onto the stack.
pub fn pushResult(lua: Lua, result: anytype) c_int {
    const ResultType = @TypeOf(result);
    const result_info = @typeInfo(ResultType);

    // Handle error unions
    if (result_info == .error_union) {
        const payload = result catch |err| {
            // Push error message to Lua and raise error
            const err_msg = @errorName(err);
            lua.state.pushString(err_msg);
            lua.state.raiseError();
        };

        // Recursively handle the success payload
        return pushResult(lua, payload);
    }

    // Handle tuple results by pushing each element individually
    if (result_info == .@"struct" and result_info.@"struct".is_tuple) {
        inline for (0..result_info.@"struct".fields.len) |i| {
            push(lua, result[i]);
        }
        return @intCast(result_info.@"struct".fields.len);
    }

    // Handle non-tuple results normally
    push(lua, result);
    return slotCountFor(ResultType);
}

/// Creates a Lua C function from a Zig function.
/// If ClosureType is provided, creates a closure requiring `pushCClosure`.
pub fn createFunc(_: Lua, value: anytype, comptime ClosureType: ?type) State.CFunction {
    const T = @TypeOf(value);
    const arg_tuple = std.meta.ArgsTuple(T);
    const arg_fields = std.meta.fields(arg_tuple);

    // Detect if first parameter should be treated as upvalues
    const has_upvalues = ClosureType != null;

    // Compile-time validation for closures
    if (has_upvalues) {
        if (arg_fields.len == 0) {
            @compileError("Closure function must have at least one parameter for upvalues");
        }
        if (arg_fields[0].type != ClosureType.?) {
            @compileError("First parameter type (" ++ @typeName(arg_fields[0].type) ++
                ") must match ClosureType (" ++ @typeName(ClosureType.?) ++ ")");
        }
    }

    // Validate Varargs is only used as the last parameter
    inline for (arg_fields, 0..) |field, i| {
        if (field.type == Lua.Varargs) {
            if (i != arg_fields.len - 1) {
                @compileError("Varargs must be the last parameter in function signature, but found at position " ++
                    std.fmt.comptimePrint("{}", .{i}) ++ " of " ++ std.fmt.comptimePrint("{}", .{arg_fields.len}));
            }
        }
    }

    return struct {
        fn f(state: ?State.LuaState) callconv(.C) c_int {
            const l = Lua.fromState(state.?);

            // Build arguments array
            var args: arg_tuple = undefined;

            // Handle first parameter - upvalues or regular argument
            const arg_start_idx = if (has_upvalues) blk: {
                // First parameter is upvalues - populate from upvalue indices
                const CT = ClosureType.?;
                const ct_info = @typeInfo(CT);

                if (ct_info == .@"struct" and ct_info.@"struct".is_tuple) {
                    // Multiple upvalues as tuple
                    const upvalues_fields = std.meta.fields(CT);
                    inline for (upvalues_fields, 0..) |field, i| {
                        const idx = State.upvalueIndex(@intCast(i + 1));
                        args[0][i] = toValue(l, field.type, idx) orelse
                            l.state.typeError(idx, @typeName(field.type));
                    }
                } else {
                    // Single upvalue
                    const idx = State.upvalueIndex(1);
                    args[0] = toValue(l, CT, idx) orelse
                        l.state.typeError(idx, @typeName(CT));
                }
                break :blk 1; // Start stack args from index 1, skip upvalue parameter
            } else blk: {
                break :blk 0; // Start stack args from index 0, no upvalue parameter
            };

            // Fill remaining arguments from Lua stack
            inline for (arg_fields[arg_start_idx..], 0..) |field, i| {
                args[i + arg_start_idx] = checkArg(l, @intCast(i + 1), field.type);
            }

            // Call Zig func and push result
            const result = @call(.auto, value, args);
            return pushResult(l, result);
        }
    }.f;
}

/// Internal function to pop a value from the Lua stack and convert it to a Zig type.
/// Used internally by table operations and other high-level functions.
pub inline fn pop(lua: Lua, comptime T: type) ?T {
    if (T == void) {
        return;
    }

    defer lua.state.pop(1);
    return toValue(lua, T, -1);
}

/// Helper function to retrieve function arguments from the Lua stack.
/// Used to invoke Lua functions with Zig arguments.
pub fn checkArg(lua: Lua, index: i32, comptime T: type) T {
    const type_info = @typeInfo(T);

    // Check if this is a Varargs type
    if (T == Lua.Varargs) {
        // This is a Varargs type - create iterator for remaining arguments
        const top = lua.state.getTop();
        const count = @max(0, top - index + 1);

        return T{
            .lua = lua,
            .base = index,
            .index = index,
            .count = count,
        };
    }

    switch (type_info) {
        .bool => {
            return lua.state.checkBoolean(index);
        },
        .int, .comptime_int => {
            const lua_int = lua.state.checkInteger(index);
            return @intCast(lua_int);
        },
        .float, .comptime_float => {
            const lua_num = lua.state.checkNumber(index);
            return @floatCast(lua_num);
        },
        .optional => {
            // Check if the argument exists at all (not passed) or is nil
            if (lua.state.getTop() < index or lua.state.isNil(index))
                return null
            else
                return checkArg(lua, index, type_info.optional.child);
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

            const lua_vec = lua.state.checkVector(index);

            if (State.VECTOR_SIZE == 4) {
                return @Vector(4, f32){ lua_vec[0], lua_vec[1], lua_vec[2], lua_vec[3] };
            } else {
                return @Vector(3, f32){ lua_vec[0], lua_vec[1], lua_vec[2] };
            }
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .one => {
                    // Handle pointer to struct (user data)
                    const child_type_info = @typeInfo(ptr_info.child);
                    if (child_type_info == .@"struct") {
                        // This is a pointer to a struct (userdata)
                        // Use the struct type name as the userdata type name
                        const type_name: [:0]const u8 = @typeName(ptr_info.child);
                        const userdata_ptr = lua.state.checkUdata(index, type_name);
                        return @ptrCast(@alignCast(userdata_ptr));
                    }

                    // Handle light user data: *T where T is not a struct or array
                    if (child_type_info == .array and child_type_info.array.child == u8) {
                        lua.state.typeError(index, "string slice");
                    }

                    // Check if this is light user data and get the pointer
                    if (!lua.state.isLightUserdata(index)) {
                        lua.state.typeError(index, "light userdata");
                    }

                    const light_userdata = lua.state.toLightUserdata(index) orelse {
                        lua.state.typeError(index, "light userdata");
                    };
                    return @ptrCast(@alignCast(light_userdata));
                },
                .slice => {
                    // Handle string slices: []const u8, [:0]const u8
                    if (ptr_info.child == u8) {
                        const lua_str = lua.state.checkString(index);

                        // Return appropriate slice type
                        if (comptime std.mem.indexOf(u8, @typeName(T), ":0") != null) {
                            // Zero-terminated slice: [:0]const u8
                            return lua_str;
                        } else {
                            // Regular slice: []const u8
                            return lua_str[0..lua_str.len];
                        }
                    }

                    lua.state.typeError(index, "unknown pointer type");
                },
                else => lua.state.typeError(index, "unsupported pointer type"),
            }
        },
        .@"struct" => {
            // Check for specific struct types
            if (T == Lua.Table) {
                // Check that the value is actually a table
                if (!lua.state.isTable(index)) {
                    lua.state.typeError(index, "table");
                }
                // Create a Table reference from the stack value
                return @as(T, Lua.Table{ .ref = Lua.Ref{ .lua = lua, .ref = lua.state.ref(index) } });
            }

            // Check for Function type
            if (T == Lua.Function) {
                // Check that the value is actually a function
                if (!lua.state.isFunction(index)) {
                    lua.state.typeError(index, "function");
                }
                // Create a Function reference from the stack value
                return @as(T, Lua.Function{ .ref = Lua.Ref{ .lua = lua, .ref = lua.state.ref(index) } });
            }

            // Handle other struct types (user data passed by value)
            // Use the struct type name as the userdata type name
            const type_name: [:0]const u8 = @typeName(T);
            const userdata_ptr = lua.state.checkUdata(index, type_name);
            const struct_ptr: *T = @ptrCast(@alignCast(userdata_ptr));
            return struct_ptr.*;
        },
        .@"union" => {
            // Check for Value type
            if (T == Lua.Value) {
                // Value can represent any Lua type, so convert based on actual type
                const lua_type = lua.state.getType(index);
                return switch (lua_type) {
                    .nil => Lua.Value{ .nil = {} },
                    .boolean => Lua.Value{ .boolean = checkArg(lua, index, bool) },
                    .number => Lua.Value{ .number = checkArg(lua, index, f64) },
                    .string => Lua.Value{ .string = checkArg(lua, index, []const u8) },
                    .table => Lua.Value{ .table = checkArg(lua, index, Lua.Table) },
                    .function => Lua.Value{ .function = checkArg(lua, index, Lua.Function) },
                    .userdata => Lua.Value{ .userdata = Lua.Ref.init(lua, index) },
                    .lightuserdata => blk: {
                        if (lua.state.toPointer(index)) |ptr| {
                            break :blk Lua.Value{ .lightuserdata = @constCast(ptr) };
                        } else {
                            break :blk Lua.Value{ .nil = {} };
                        }
                    },
                    else => Lua.Value{ .nil = {} },
                };
            }

            lua.state.typeError(index, "unsupported union type");
        },
        else => {
            lua.state.typeError(index, "unsupported type");
        },
    }
}

/// Internal function to convert a single Lua value at the specified stack index to a Zig type.
///
/// This function always expects to handle exactly one Lua stack slot and does not handle composite types like tuples.
/// For composite types, use higher-level functions that manage multiple stack slots appropriately.
pub fn toValue(lua: Lua, comptime T: type, index: i32) ?T {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .bool => {
            return if (lua.state.isBoolean(index))
                lua.state.toBoolean(index)
            else
                null;
        },
        .int, .comptime_int => {
            return if (lua.state.toIntegerX(index)) |integer|
                @intCast(integer)
            else
                null;
        },
        .float, .comptime_float => {
            return if (lua.state.toNumberX(index)) |number|
                @floatCast(number)
            else
                null;
        },
        .optional => {
            return if (lua.state.isNil(index))
                null
            else
                toValue(lua, type_info.optional.child, index);
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

            if (!lua.state.isVector(index)) {
                return null;
            }

            const lua_vec = lua.state.toVector(index) orelse return null;

            return if (State.VECTOR_SIZE == 4)
                @Vector(4, f32){ lua_vec[0], lua_vec[1], lua_vec[2], lua_vec[3] }
            else
                @Vector(3, f32){ lua_vec[0], lua_vec[1], lua_vec[2] };
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .one => {
                    // Handle light user data: *T where T is not an array
                    const child_type_info = @typeInfo(ptr_info.child);
                    if (child_type_info == .array and child_type_info.array.child == u8) {
                        // String arrays are not supported for toValue (only push)
                        return null;
                    }

                    // Check if this is light user data
                    if (!lua.state.isLightUserdata(index)) {
                        return null;
                    }

                    const light_userdata = lua.state.toLightUserdata(index) orelse return null;
                    return @ptrCast(@alignCast(light_userdata));
                },
                .slice => {
                    // Handle string slices: []const u8, [:0]const u8
                    if (ptr_info.child == u8) {
                        // Check if the value is actually a string to avoid conversion
                        // Use getType instead of isString because isString returns true for numbers too
                        if (lua.state.getType(index) != .string) {
                            return null;
                        }

                        const lua_str = lua.state.toString(index) orelse return null;

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
            if (T == Lua.Ref) {
                // Create a reference to any value on the stack
                return Lua.Ref{ .lua = lua, .ref = lua.state.ref(index) };
            } else if (T == Lua.Table) {
                // Create a Table reference if the value is a table
                if (!lua.state.isTable(index)) {
                    return null;
                }
                return Lua.Table{ .ref = Lua.Ref{ .lua = lua, .ref = lua.state.ref(index) } };
            } else if (T == Lua.Function) {
                // Create a Function reference if the value is a function
                if (!lua.state.isFunction(index)) {
                    return null;
                }
                return Lua.Function{ .ref = Lua.Ref{ .lua = lua, .ref = lua.state.ref(index) } };
            }

            @compileError("Unsupported struct type " ++ @typeName(T));
        },
        .@"union" => {
            // Handle Value union
            if (T == Lua.Value) {
                const lua_type = lua.state.getType(index);

                return switch (lua_type) {
                    .nil => Lua.Value.nil,
                    .boolean => Lua.Value{ .boolean = lua.state.toBoolean(index) },
                    .number => if (lua.state.toNumberX(index)) |num|
                        Lua.Value{ .number = num }
                    else
                        null,
                    .string => if (lua.state.toString(index)) |str|
                        Lua.Value{ .string = str[0..str.len] }
                    else
                        null,
                    .table => if (toValue(lua, Lua.Table, index)) |table|
                        Lua.Value{ .table = table }
                    else
                        null,
                    .function => if (toValue(lua, Lua.Function, index)) |func|
                        Lua.Value{ .function = func }
                    else
                        null,
                    .userdata => if (lua.state.isUserdata(index))
                        Lua.Value{ .userdata = Lua.Ref{ .lua = lua, .ref = lua.state.ref(index) } }
                    else
                        null,
                    .lightuserdata => if (lua.state.toLightUserdata(index)) |data|
                        Lua.Value{ .lightuserdata = data }
                    else
                        null,
                    else => null,
                };
            }

            @compileError("Unsupported union type " ++ @typeName(T));
        },
        else => {
            @compileError("Unable to cast type " ++ @typeName(T));
        },
    }
}

// Tests
const expect = std.testing.expect;
const expectEq = std.testing.expectEqual;

test "push and pop types" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test integers
    push(lua, @as(i32, 42));
    try expectEq(pop(lua, i32).?, 42);

    // Test floats
    push(lua, @as(f64, 3.14));
    try expectEq(pop(lua, f64).?, 3.14);

    // Test booleans
    push(lua, true);
    try expect(pop(lua, bool).?);

    // Test optional with value
    push(lua, @as(?i32, 42));
    try expectEq(pop(lua, ?i32).?, 42);

    // Test optional null
    push(lua, @as(?i32, null));
    try expect(pop(lua, ?i32) == null);

    // Test zero and negative values
    push(lua, @as(i32, 0));
    try expectEq(pop(lua, i32).?, 0);

    push(lua, @as(i32, -42));
    try expectEq(pop(lua, i32).?, -42);

    // Test comptime values
    push(lua, 123);
    try expectEq(pop(lua, i32).?, 123);

    try expectEq(lua.state.getTop(), 0);
}

test "push and pop vector types" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const vec3 = @Vector(3, f32){ 1.0, 2.0, 3.0 };
    push(lua, vec3);
    try expect(lua.state.isVector(-1));
    const popped_vec3 = pop(lua, @Vector(3, f32)).?;
    try expectEq(popped_vec3[0], 1.0);
    try expectEq(popped_vec3[1], 2.0);
    try expectEq(popped_vec3[2], 3.0);

    try expectEq(lua.state.getTop(), 0);
}

test "string operations" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test basic string push
    push(lua, "hello");
    try expect(lua.state.isString(-1));
    lua.state.pop(1);

    // Test string retrieval
    push(lua, "hello world");
    const str_slice = toValue(lua, []const u8, -1);
    try expect(str_slice != null);
    try expect(std.mem.eql(u8, str_slice.?, "hello world"));
    lua.state.pop(1);

    // Test that numbers don't get converted to strings
    push(lua, @as(i32, 42));
    const not_string = toValue(lua, []const u8, -1);
    try expect(not_string == null);
    lua.state.pop(1);

    try expectEq(lua.state.getTop(), 0);
}

test "toValue type conversions" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    // Test string to slice conversion
    lua.state.pushString("hello world");
    const str_slice = toValue(lua, []const u8, -1);
    try expect(str_slice != null);
    try expect(std.mem.eql(u8, str_slice.?, "hello world"));
    lua.state.pop(1);

    // Test that numbers don't get converted to strings
    lua.state.pushNumber(42);
    try expect(toValue(lua, []const u8, -1) == null);
    lua.state.pop(1);

    // Test reference types
    lua.state.newTable();
    const table_ref = toValue(lua, Lua.Table, -1);
    try expect(table_ref != null);
    table_ref.?.ref.deinit();
    lua.state.pop(1);

    // Test function references
    const testFn = struct {
        fn f(a: i32) i32 {
            return a * 2;
        }
    }.f;
    push(lua, testFn);
    const func_ref = toValue(lua, Lua.Function, -1);
    try expect(func_ref != null);
    func_ref.?.ref.deinit();
    lua.state.pop(1);
}

test "push structs as tables" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const Point = struct {
        x: i32,
        y: i32,
        name: []const u8,
    };

    const point = Point{ .x = 10, .y = 20, .name = "origin" };
    push(lua, point);

    try expect(lua.state.isTable(-1));

    // Test accessing fields
    lua.state.pushString("x");
    _ = lua.state.getTable(-2);
    try expectEq(pop(lua, i32).?, 10);

    lua.state.pushString("y");
    _ = lua.state.getTable(-2);
    try expectEq(pop(lua, i32).?, 20);

    lua.state.pushString("name");
    _ = lua.state.getTable(-2);
    const name = toValue(lua, []const u8, -1);
    try expect(name != null);
    try expect(std.mem.eql(u8, name.?, "origin"));
    lua.state.pop(1);

    lua.state.pop(1); // Pop table
    try expectEq(lua.state.getTop(), 0);
}

test "push arrays as tables" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const arr = [_]i32{ 1, 2, 3, 4, 5 };
    push(lua, arr);

    try expect(lua.state.isTable(-1));

    // Test accessing array elements (1-indexed in Lua)
    for (arr, 1..) |expected, i| {
        _ = lua.state.rawGetI(-1, @intCast(i));
        try expectEq(pop(lua, i32).?, expected);
    }

    lua.state.pop(1); // Pop table
    try expectEq(lua.state.getTop(), 0);
}

test "push slices as tables" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const arr = [_]f64{ 1.1, 2.2, 3.3 };
    const slice: []const f64 = &arr;
    push(lua, slice);

    try expect(lua.state.isTable(-1));

    // Test accessing slice elements (1-indexed in Lua)
    for (slice, 1..) |expected, i| {
        _ = lua.state.rawGetI(-1, @intCast(i));
        try expectEq(pop(lua, f64).?, expected);
    }

    lua.state.pop(1); // Pop table
    try expectEq(lua.state.getTop(), 0);
}

test "push nested structs and arrays" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const Config = struct {
        values: [3]i32,
        enabled: bool,
    };

    const config = Config{ .values = [_]i32{ 10, 20, 30 }, .enabled = true };
    push(lua, config);

    try expect(lua.state.isTable(-1));

    // Test accessing nested array
    lua.state.pushString("values");
    _ = lua.state.getTable(-2);
    try expect(lua.state.isTable(-1));

    // Check array contents
    _ = lua.state.rawGetI(-1, 1);
    try expectEq(pop(lua, i32).?, 10);
    _ = lua.state.rawGetI(-1, 2);
    try expectEq(pop(lua, i32).?, 20);
    _ = lua.state.rawGetI(-1, 3);
    try expectEq(pop(lua, i32).?, 30);

    lua.state.pop(1); // Pop values array

    // Test accessing boolean field
    lua.state.pushString("enabled");
    _ = lua.state.getTable(-2);
    try expect(pop(lua, bool).?);

    lua.state.pop(1); // Pop config table
    try expectEq(lua.state.getTop(), 0);
}
