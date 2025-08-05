//! This module provides a bunch of magic comptime reflection helpers to build Lua userdata types.

const std = @import("std");
const State = @import("state.zig").State;
const ArgsTuple = std.meta.ArgsTuple;
const stack = @import("stack.zig");
const Lua = @import("lua.zig").Lua;

/// Supported metamethods
const MetaMethod = enum {
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

/// Function type categories for userdata methods
const FunctionType = enum {
    init, // Constructor functions
    instance, // Instance methods (with Self parameter)
    static, // Static functions (no Self parameter)
    metamethod, // Metamethods (special functions like __len)
};

/// Checks if a type is Self (T) or a pointer to Self (*T)
fn isSelf(comptime T: type, comptime param_type: type) bool {
    if (param_type == T) {
        return true; // T
    }

    const param_info = @typeInfo(param_type);
    if (param_info == .pointer and param_info.pointer.size == .one) {
        return param_info.pointer.child == T; // *T
    }

    return false;
}

/// Detects if a method is a metamethod, validates its signature, and returns its type
fn isMetaMethod(comptime method_name: []const u8, comptime method: anytype) ?MetaMethod {
    const meta_method = comptime MetaMethod.fromStr(method_name);
    if (meta_method == null) return null;
    const method_info = @typeInfo(@TypeOf(method));

    // Validate signature based on metamethod type
    switch (meta_method.?) {
        // Validates signature: fn(self) number_type
        .len => {
            if (method_info.@"fn".params.len != 1) {
                @compileError("__len metamethod must take exactly one parameter (self), got " ++
                    std.fmt.comptimePrint("{}", .{method_info.@"fn".params.len}));
            }

            const return_type = method_info.@"fn".return_type orelse
                @compileError("__len metamethod must have a return type (should return a number)");

            const return_info = @typeInfo(return_type);
            const is_number = switch (return_info) {
                .int, .comptime_int => true,
                .float, .comptime_float => true,
                else => false,
            };

            if (!is_number) {
                @compileError("__len metamethod must return a number type, got " ++ @typeName(return_type));
            }
        },

        // Validates signature: fn(self) []const u8
        .tostring => {
            if (method_info.@"fn".params.len != 1) {
                @compileError("__tostring metamethod must take exactly one parameter (self), got " ++
                    std.fmt.comptimePrint("{}", .{method_info.@"fn".params.len}));
            }

            const return_type = method_info.@"fn".return_type orelse
                @compileError("__tostring metamethod must have a return type (should return []const u8)");

            const return_info = @typeInfo(return_type);
            const is_string = switch (return_info) {
                .pointer => |ptr| ptr.size == .slice and ptr.child == u8 and ptr.is_const,
                else => false,
            };

            if (!is_string) {
                @compileError("__tostring metamethod must return []const u8, got " ++ @typeName(return_type));
            }
        },

        // Validates signature: fn(self) return_type
        .unm => {
            if (method_info.@"fn".params.len != 1) {
                @compileError("__unm metamethod must take exactly one parameter (self), got " ++
                    std.fmt.comptimePrint("{}", .{method_info.@"fn".params.len}));
            }

            _ = method_info.@"fn".return_type orelse
                @compileError("__unm metamethod must have a return type");
        },

        // Validates signature: fn(self, other) return_type
        .add, .sub, .mul, .div, .idiv, .mod, .pow, .eq, .lt, .le, .concat => {
            if (method_info.@"fn".params.len != 2) {
                @compileError(method_name ++ " metamethod must take exactly two parameters (self, other), got " ++
                    std.fmt.comptimePrint("{}", .{method_info.@"fn".params.len}));
            }

            _ = method_info.@"fn".return_type orelse
                @compileError(method_name ++ " metamethod must have a return type");
        },

        // Validates signature: fn(self, key) return_type - key can be any valid Lua type or Lua.Value for generic runtime values
        .index => {
            if (method_info.@"fn".params.len != 2) {
                @compileError("__index metamethod must take exactly two parameters (self, key), got " ++
                    std.fmt.comptimePrint("{}", .{method_info.@"fn".params.len}));
            }

            _ = method_info.@"fn".return_type orelse
                @compileError("__index metamethod must have a return type");
        },

        // Validates signature: fn(self, key, value) void - key and value can be any valid Lua type or Lua.Value for generic runtime values
        .newindex => {
            if (method_info.@"fn".params.len != 3) {
                @compileError("__newindex metamethod must take exactly three parameters (self, key, value), got " ++
                    std.fmt.comptimePrint("{}", .{method_info.@"fn".params.len}));
            }

            const return_type = method_info.@"fn".return_type;
            if (return_type != null and return_type != void) {
                @compileError("__newindex metamethod must return void or have no return type, got " ++
                    @typeName(return_type.?));
            }
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
            fn dtor(ptr: ?*anyopaque) callconv(.C) void {
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

/// Determines function type and validates constraints for userdata methods.
/// Categorizes as init (constructor), instance method, static function, or metamethod.
///
/// Init functions must be static and return T. Instance methods take T or *T as first parameter.
/// Metamethods have specific signature requirements validated at compile time.
fn getFunctionType(comptime T: type, comptime method_name: []const u8, method: anytype) FunctionType {
    const is_init = std.mem.eql(u8, method_name, "init");

    // Check if this is a metamethod first
    if (isMetaMethod(method_name, method)) |_| {
        return .metamethod;
    }

    const method_info = @typeInfo(@TypeOf(method));

    // Determine if function is static (doesn't take Self as first parameter)
    var is_static = true;
    if (method_info.@"fn".params.len > 0) {
        const first_param = method_info.@"fn".params[0];
        if (first_param.type) |param_type| {
            is_static = !isSelf(T, param_type);
        }
    }

    if (is_init) {
        // Validate init function constraints
        if (!is_static) {
            @compileError("init function must be static - it cannot take Self as parameter");
        }

        const return_type = method_info.@"fn".return_type orelse @compileError("init function must have a return type");

        if (return_type != T) {
            @compileError("init function must return " ++ @typeName(T) ++ ", got " ++ @typeName(return_type));
        }

        return .init;
    } else if (is_static) {
        return .static;
    } else {
        return .instance;
    }
}

/// Creates a Lua C function wrapper from a Zig method that operates on userdata.
///
/// Generates a C-compatible function that handles translation between Lua's stack-based
/// calling convention and Zig's typed function calls. Supports init functions (constructors),
/// instance methods, and static functions. If the struct has a deinit method, userdata
/// created by init functions will automatically call deinit when garbage collected.
fn createUserDataFunc(comptime T: type, comptime method_name: []const u8, method: anytype, comptime type_name: [:0]const u8) State.CFunction {
    const MethodType = @TypeOf(method);
    const method_info = @typeInfo(MethodType);
    const function_type = comptime getFunctionType(T, method_name, method);

    return struct {
        fn f(state: ?State.LuaState) callconv(.C) c_int {
            const lua = Lua.fromState(state.?);

            // Init is a special method that is responsible for object construction.
            var instance_ptr: ?*T = null;
            if (function_type == .init) {
                instance_ptr = createUserDataInstance(T, lua, type_name) orelse return 0;
            }

            // For instance methods and metamethods, the first parameter must be either Self or *Self.
            // In this case, we should retrieve a userdata pointer to our structure.
            var instance: ?*T = null;
            if (function_type == .instance or function_type == .metamethod) {
                const userdata = lua.state.checkUdata(1, type_name);
                instance = @ptrCast(@alignCast(userdata));
            }

            // Fetches function params from Lua stack.
            // In case of instance method, instance pointer is passed.
            var args: ArgsTuple(MethodType) = if (method_info.@"fn".params.len == 0) .{} else undefined;
            inline for (0..method_info.@"fn".params.len) |i| {
                const param_type = method_info.@"fn".params[i].type orelse @compileError("Parameter type required");

                if (i == 0 and (function_type == .instance or function_type == .metamethod)) {
                    // Handle self parameter - determine if method expects T or *T
                    if (param_type == T) {
                        args[i] = instance.?.*; // Immutable self (T)
                    } else {
                        args[i] = instance.?; // Mutable self (*T)
                    }
                } else {
                    // Handle regular parameters from Lua stack
                    const lua_stack_index = i + 1;

                    // Special handling for __index and __newindex metamethods that use Lua.Value
                    if ((function_type == .metamethod) and
                        (std.mem.eql(u8, method_name, "__index") or std.mem.eql(u8, method_name, "__newindex")) and
                        param_type == Lua.Value)
                    {
                        args[i] = stack.toValue(lua, Lua.Value, @intCast(lua_stack_index)) orelse Lua.Value.nil;
                    } else {
                        args[i] = stack.checkArg(lua, @intCast(lua_stack_index), param_type);
                    }
                }
            }

            const result = @call(.auto, method, args);

            if (function_type == .init) {
                // Init functions must return exactly one value (the userdata)
                if (comptime stack.slotCountFor(@TypeOf(result)) != 1) {
                    @compileError("init function must return exactly one value, got " ++ @typeName(@TypeOf(result)));
                }

                // Copy returned struct into allocated userdata
                instance_ptr.?.* = result;
                return 1;
            }

            // Otherwise handle pushing values returned from the function.
            // Void pushes nothing.
            // Tuples push all elements to the stack.
            // Otherwise use push as a fallback to push a single item from the list of supported types to the stack.
            const ResultType = @TypeOf(result);
            const result_info = @typeInfo(ResultType);
            if (result_info == .@"struct" and result_info.@"struct".is_tuple) {
                // Multiple return values
                inline for (0..result_info.@"struct".fields.len) |i| {
                    stack.push(lua, result[i]);
                }
                return @intCast(result_info.@"struct".fields.len);
            } else if (ResultType == T) {
                // Handle userdata return type (e.g., from metamethods like __add)
                const result_ptr = createUserDataInstance(T, lua, type_name) orelse return 0;
                result_ptr.* = result;
                return 1;
            } else {
                stack.push(lua, result);
                return stack.slotCountFor(ResultType);
            }
        }
    }.f;
}

/// Creates and registers a complete metatable for userdata type T.
///
/// This is the main public API for userdata registration. It counts methods,
/// creates the metatable, registers all methods (init, instance, static),
/// and registers metamethods. Returns the number of methods registered.
///
/// The type_name will be used for Lua userdata type checking and must be
/// a compile-time string literal ending with null terminator.
pub fn createMetaTable(comptime T: type, lua_state: *State, comptime type_name: [:0]const u8) u32 {
    const struct_info = @typeInfo(T).@"struct";

    // Detect what kind of methods we have in this struct
    // We're interested in:
    // - How many public methods (not deinit, not metamethods)
    // - Whether __index metamethod is going to be defined by the user
    var method_count: u32 = 0;
    comptime var has_user_index = false;
    inline for (struct_info.decls) |decl| {
        if (@hasDecl(T, decl.name)) {
            const decl_info = @typeInfo(@TypeOf(@field(T, decl.name)));
            if (decl_info == .@"fn") {
                // Check for __index metamethod
                if (comptime std.mem.eql(u8, decl.name, "__index")) {
                    has_user_index = true;
                }

                // Count regular methods (not deinit, not metamethods)
                if (!comptime std.mem.eql(u8, decl.name, "deinit") and
                    MetaMethod.fromStr(decl.name) == null)
                {
                    method_count += 1;
                }
            }
        }
    }

    // Create the metatable for this userdata type
    if (!lua_state.newMetatable(type_name)) {
        @panic("Type " ++ @typeName(T) ++ " is already registered");
    }

    // Set __index to self for method lookup (when no user __index is defined)
    if (!comptime has_user_index) {
        lua_state.pushValue(-1);
        lua_state.setField(-2, "__index");
    }

    // Register all regular methods (init, instance, static) - excluding metamethods and deinit
    inline for (struct_info.decls) |decl| {
        if (@hasDecl(T, decl.name)) {
            const decl_info = @typeInfo(@TypeOf(@field(T, decl.name)));
            if (decl_info == .@"fn" and
                !comptime std.mem.eql(u8, decl.name, "deinit") and
                    MetaMethod.fromStr(decl.name) == null)
            {
                const method_func = @field(T, decl.name);

                // Use "new" as the name for init functions, otherwise use the method name
                const lua_name = if (comptime std.mem.eql(u8, decl.name, "init")) "new" else decl.name;
                lua_state.pushCFunction(createUserDataFunc(T, decl.name, method_func, type_name), lua_name);
                lua_state.setField(-2, lua_name);
            }
        }
    }

    // Register metamethods
    inline for (struct_info.decls) |decl| {
        if (@hasDecl(T, decl.name)) {
            const decl_info = @typeInfo(@TypeOf(@field(T, decl.name)));
            if (decl_info == .@"fn") {
                const method_func = @field(T, decl.name);
                if (MetaMethod.fromStr(decl.name)) |_| {
                    // Validate metamethod signature before registering
                    _ = isMetaMethod(decl.name, method_func);

                    // Register metamethod in the metatable
                    lua_state.pushCFunction(createUserDataFunc(T, decl.name, method_func, type_name), decl.name);
                    lua_state.setField(-2, decl.name);
                }
            }
        }
    }

    // Store the metatable in the registry for later use
    lua_state.setField(State.REGISTRYINDEX, type_name);

    return method_count;
}
