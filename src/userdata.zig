//! This module provides a bunch of magic comptime reflection helpers to build Lua userdata types.

const std = @import("std");
const State = @import("State.zig");
const ArgsTuple = std.meta.ArgsTuple;
const stack = @import("stack.zig");
const Lua = @import("Lua.zig");
const comptimePrint = std.fmt.comptimePrint;

/// Supported metamethods
pub const MetaMethod = enum {
    len, // __len
    tostring, // __tostring
    add, // __add
    sub, // __sub
    mul, // __mul
    div, // __div
    idiv, // __idiv
    mod, // __mod
    pow, // __pow
    unm, // __unm
    eq, // __eq
    lt, // __lt
    le, // __le
    concat, // __concat
    index, // __index
    newindex, // __newindex

    /// Parse metamethod name from string, returns null if not a metamethod or unsupported
    pub fn fromStr(method_name: []const u8) ?MetaMethod {
        const name_map = std.StaticStringMap(MetaMethod).initComptime(.{
            .{ "__len", .len },
            .{ "__tostring", .tostring },
            .{ "__add", .add },
            .{ "__sub", .sub },
            .{ "__mul", .mul },
            .{ "__div", .div },
            .{ "__idiv", .idiv },
            .{ "__mod", .mod },
            .{ "__pow", .pow },
            .{ "__unm", .unm },
            .{ "__eq", .eq },
            .{ "__lt", .lt },
            .{ "__le", .le },
            .{ "__concat", .concat },
            .{ "__index", .index },
            .{ "__newindex", .newindex },
        });

        return name_map.get(method_name);
    }
};

/// Detects if a method is a metamethod, validates its signature, and returns its type
pub fn isMetaMethod(comptime method_name: []const u8, comptime method: anytype) ?MetaMethod {
    const meta_method = comptime MetaMethod.fromStr(method_name);
    if (meta_method == null) return null;
    const method_info = @typeInfo(@TypeOf(method));
    const param_count = method_info.@"fn".params.len;
    const return_type = method_info.@"fn".return_type orelse
        @compileError("metamethod " ++ method_name ++ " must have a return type");

    // Validate signature based on metamethod type
    switch (meta_method.?) {
        // Validates signature: fn(self) number_type
        .len => {
            if (param_count != 1)
                @compileError("__len metamethod must take exactly one parameter (self), got " ++
                    comptimePrint("{}", .{param_count}));

            const is_number = switch (@typeInfo(return_type)) {
                .int, .comptime_int, .float, .comptime_float => true,
                else => false,
            };

            if (!is_number)
                @compileError("__len metamethod must return a number type, got " ++ @typeName(return_type));
        },

        // Validates signature: fn(self) []const u8
        .tostring => {
            if (param_count != 1)
                @compileError("__tostring metamethod must take exactly one parameter (self), got " ++
                    comptimePrint("{}", .{param_count}));

            const is_string = switch (@typeInfo(return_type)) {
                .pointer => |ptr| ptr.size == .slice and ptr.child == u8 and ptr.is_const,
                else => false,
            };

            if (!is_string)
                @compileError("__tostring metamethod must return []const u8, got " ++ @typeName(return_type));
        },

        // Validates signature: fn(self) return_type
        .unm => {
            if (param_count != 1)
                @compileError("__unm metamethod must take exactly one parameter (self), got " ++
                    comptimePrint("{}", .{param_count}));
        },

        // Validates signature: fn(self, other) return_type
        .add, .sub, .mul, .div, .idiv, .mod, .pow, .eq, .lt, .le, .concat => {
            if (param_count != 2)
                @compileError(method_name ++ " metamethod must take exactly two parameters (self, other), got " ++
                    comptimePrint("{}", .{param_count}));
        },

        // Validates signature: fn(self, key) return_type - key can be any valid Lua type or Lua.Value for generic runtime values
        .index => {
            if (param_count != 2)
                @compileError("__index metamethod must take exactly two parameters (self, key), got " ++
                    comptimePrint("{}", .{param_count}));
        },

        // Validates signature: fn(self, key, value) void - key and value can be any valid Lua type or Lua.Value for generic runtime values
        .newindex => {
            if (param_count != 3)
                @compileError("__newindex metamethod must take exactly three parameters (self, key, value), got " ++
                    comptimePrint("{}", .{param_count}));

            if (return_type != void)
                @compileError("__newindex metamethod must return void, got " ++
                    @typeName(return_type));
        },
    }

    return meta_method.?;
}

/// Creates a new userdata instance and attaches the metatable.
/// Uses newUserdata to create userdata, or newUserdataDtor if T has a deinit method.
/// Attaches the type's metatable for method dispatch.
/// Returns a typed pointer to the userdata, or null if allocation fails.
fn createUserDataInstance(comptime T: type, lua: Lua, comptime type_name: [:0]const u8) ?*T {
    // Allocate userdata with optional destructor support
    const userdata = if (comptime @hasDecl(T, "deinit")) blk: {
        const DtorImpl = struct {
            fn dtor(ptr: ?*anyopaque) callconv(.c) void {
                if (ptr) |p| {
                    const obj: *T = @ptrCast(@alignCast(p));
                    obj.deinit();
                }
            }
        };
        break :blk lua.state.newUserdataDtor(@sizeOf(T), DtorImpl.dtor);
    } else lua.state.newUserdata(@sizeOf(T));

    const ptr = userdata orelse return null;
    const instance_ptr: *T = @ptrCast(@alignCast(ptr));

    // Attach metatable for method dispatch and metamethods
    if (lua.state.getField(State.REGISTRYINDEX, type_name) != State.Type.nil) {
        _ = lua.state.setMetatable(-2);
    } else {
        lua.state.pop(1);
    }

    return instance_ptr;
}

/// Pushes a function result onto the Lua stack, with optional userdata creation.
fn pushResult(comptime T: type, lua: Lua, result: anytype, comptime type_name: [:0]const u8, comptime userdata: bool) c_int {
    const ResultType = @TypeOf(result);
    const result_info = @typeInfo(ResultType);

    // Extract value from error union if needed
    const value = if (result_info == .error_union)
        result catch |err| {
            const err_msg = @errorName(err);
            lua.state.pushString(err_msg);
            lua.state.raiseError();
        }
    else
        result;

    if (userdata) {
        // Create new userdata instance and copy the value
        const result_ptr = createUserDataInstance(T, lua, type_name) orelse return 0;
        result_ptr.* = value;
        return 1;
    }

    // For all other cases, use the standard pushResult
    return stack.pushResult(&lua.state, value);
}

/// Generates a function that handles translation between Lua's stack-based
/// calling convention and Zig's typed function calls. Supports init functions (constructors),
/// instance methods, and static functions. If the struct has a deinit method, userdata
/// created by init functions will automatically call deinit when garbage collected.
pub fn createUserDataFunc(comptime T: type, comptime method_name: []const u8, method: anytype, comptime type_name: [:0]const u8) State.CFunction {
    const MethodType = @TypeOf(method);
    const method_info = @typeInfo(MethodType);
    const metamethod_type = comptime isMetaMethod(method_name, method);

    const is_init = comptime std.mem.eql(u8, method_name, "init");
    const is_static = comptime blk: {
        if (method_info.@"fn".params.len == 0) break :blk true;
        const first_param = method_info.@"fn".params[0];
        const param_type = first_param.type orelse break :blk true;
        // Check if param_type is Self (T) or pointer to Self (*T)
        if (param_type == T) break :blk false;
        const param_info = @typeInfo(param_type);
        break :blk !(param_info == .pointer and
            param_info.pointer.size == .one and
            param_info.pointer.child == T);
    };

    // Validate init function constraints
    if (comptime is_init) {
        if (!is_static)
            @compileError("init function must be static - it cannot take Self as parameter");

        const return_type = method_info.@"fn".return_type;
        if (return_type != T)
            @compileError("init function must return " ++ @typeName(T) ++ ", got " ++ @typeName(return_type orelse void));

        if (comptime stack.slotCountFor(return_type orelse void) != 1)
            @compileError("init function must return exactly one value, got " ++ @typeName(return_type orelse void));
    }

    return struct {
        fn f(state: ?State.LuaState) callconv(.c) c_int {
            const lua = Lua.fromState(state.?);

            // Fetch function params from Lua stack
            var args: ArgsTuple(MethodType) = undefined;
            inline for (method_info.@"fn".params, 0..) |param, i| {
                const param_type = param.type orelse @compileError("Parameter type required");

                const lua_stack_index = i + 1;
                const is_meta_index = metamethod_type != null and (metamethod_type.? == .index or metamethod_type.? == .newindex);

                args[i] = if (i == 0 and !is_static) blk: {
                    // Retrieve userdata pointer for instance methods and metamethods
                    const userdata = lua.state.checkUdata(1, type_name);
                    const instance: *T = @ptrCast(@alignCast(userdata));
                    break :blk if (param_type == T) instance.* else instance;
                } else if (is_meta_index and param_type == Lua.Value)
                    // Special handling for __index and __newindex metamethods that use Lua.Value
                    stack.toValue(lua, Lua.Value, @intCast(lua_stack_index)) orelse Lua.Value.nil
                else
                    // Handle regular parameters from Lua stack
                    stack.checkArg(lua, @intCast(lua_stack_index), param_type);
            }

            const result = @call(.auto, method, args);

            // Handle pushing values returned from the function
            // Create userdata for init functions, or metamethods that return Self
            const should_create_userdata = is_init or
                (metamethod_type != null and @TypeOf(result) == T);
            return pushResult(T, lua, result, type_name, should_create_userdata);
        }
    }.f;
}

/// Creates a metatable for userdata type T and leaves it on the stack.
///
/// The caller must handle the metatable on the stack (store in registry, set as global, or pop).
/// The type_name must be a compile-time null-terminated string for userdata type checking.
pub fn createMetaTable(comptime T: type, lua_state: *State, comptime type_name: [:0]const u8) void {
    const struct_info = @typeInfo(T).@"struct";

    // Check if user defines __index metamethod
    const has_user_index = comptime blk: {
        for (struct_info.decls) |decl| {
            if (@hasDecl(T, decl.name) and std.mem.eql(u8, decl.name, "__index")) {
                const decl_info = @typeInfo(@TypeOf(@field(T, decl.name)));
                if (decl_info == .@"fn") break :blk true;
            }
        }
        break :blk false;
    };

    // Create a new table for the metatable (doesn't register in Lua's internal registry)
    lua_state.createTable(0, 0);

    // Set __index to self for method lookup (when no user __index is defined)
    if (!has_user_index) {
        lua_state.pushValue(-1);
        lua_state.setField(-2, "__index");
    }

    // Register all methods
    inline for (struct_info.decls) |decl| {
        if (!@hasDecl(T, decl.name)) continue;

        const decl_info = @typeInfo(@TypeOf(@field(T, decl.name)));
        if (decl_info != .@"fn") continue;

        // Skip deinit - it's handled internally
        if (comptime std.mem.eql(u8, decl.name, "deinit")) continue;

        const method_func = @field(T, decl.name);

        // Use "new" for init functions, otherwise use original name
        const lua_name = if (comptime std.mem.eql(u8, decl.name, "init"))
            "new"
        else
            decl.name;

        lua_state.pushCFunction(createUserDataFunc(T, decl.name, method_func, type_name), lua_name);
        lua_state.setField(-2, lua_name);
    }
}
