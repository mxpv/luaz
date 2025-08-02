const std = @import("std");
const State = @import("state.zig").State;
const ArgsTuple = std.meta.ArgsTuple;
const Lua = @import("lib.zig").Lua;

/// Function type categories for userdata methods
pub const FunctionType = enum {
    init, // Constructor functions
    instance, // Instance methods (with Self parameter)
    static, // Static functions (no Self parameter)
};

/// Determines function type and validates constraints for userdata methods.
/// Categorizes as init (constructor), instance method, or static function.
/// Init functions must be static and return T. Instance methods take T or *T as first parameter.
fn getFunctionType(comptime T: type, comptime method_name: []const u8, method: anytype) FunctionType {
    const is_init = std.mem.eql(u8, method_name, "init");
    const method_info = @typeInfo(@TypeOf(method));

    // Determine if function is static (doesn't take Self as first parameter)
    var is_static = true;
    if (method_info.@"fn".params.len > 0) {
        const first_param = method_info.@"fn".params[0];
        if (first_param.type) |param_type| {
            const param_info = @typeInfo(param_type);

            // Check if first parameter is T or *T
            if (param_info == .pointer and param_info.pointer.size == .one) {
                // Check if it's *T - if so, it's an instance method
                is_static = param_info.pointer.child != T;
            } else {
                // Check if it's T - if so, it's an instance method
                is_static = param_type != T;
            }
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
pub fn createUserDataFunc(comptime T: type, comptime method_name: []const u8, method: anytype, comptime type_name: [:0]const u8) State.CFunction {
    const MethodType = @TypeOf(method);
    const method_info = @typeInfo(MethodType);
    const function_type = comptime getFunctionType(T, method_name, method);

    return struct {
        fn f(state: ?State.LuaState) callconv(.C) c_int {
            const lua = Lua.fromState(state.?);

            // Init is a special method that is responsible for object construction.
            // Calls Lua's newUserdata method to allocate memory.
            // If there is a destructor, uses newUserdataDtor instead and passes deinit as destructor.
            // Lua calls this during garbage collection.
            var instance_ptr: ?*T = null;
            if (function_type == .init) {
                // Check if T has a deinit method to use destructor version
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

                const ptr = userdata orelse return 0;
                instance_ptr = @ptrCast(@alignCast(ptr));

                // Attach metatable for method dispatch
                if (lua.state.getField(State.REGISTRYINDEX, type_name) != State.Type.nil) {
                    _ = lua.state.setMetatable(-2);
                } else {
                    lua.state.pop(1);
                }
            }

            // For instance methods, the first parameter must be either Self or *Self.
            // In this case, we should retrieve a userdata pointer to our structure.
            var instance: ?*T = null;
            if (function_type == .instance) {
                const userdata = lua.state.checkUdata(1, type_name);
                instance = @ptrCast(@alignCast(userdata));
            }

            // Fetches function params from Lua stack.
            // In case of instance method, instance pointer is passed.
            var args: ArgsTuple(MethodType) = if (method_info.@"fn".params.len == 0) .{} else undefined;
            inline for (0..method_info.@"fn".params.len) |i| {
                const param_type = method_info.@"fn".params[i].type orelse @compileError("Parameter type required");

                if (i == 0 and function_type == .instance) {
                    // Handle self parameter - determine if method expects T or *T
                    const param_info = @typeInfo(param_type);
                    if (param_info == .pointer and param_info.pointer.size == .one) {
                        args[i] = instance.?; // Mutable self (*T)
                    } else {
                        args[i] = instance.?.*; // Immutable self (T)
                    }
                } else {
                    // Handle regular parameters from Lua stack
                    const lua_stack_index = i + 1;
                    args[i] = lua.checkArg(@intCast(lua_stack_index), param_type);
                }
            }

            const result = @call(.auto, method, args);

            if (function_type == .init) {
                // Init functions must return exactly one value (the userdata)
                if (comptime Lua.slotCount(@TypeOf(result)) != 1) {
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
                    lua.push(result[i]);
                }
                return @intCast(result_info.@"struct".fields.len);
            } else {
                lua.push(result);
                return Lua.slotCount(ResultType);
            }
        }
    }.f;
}
