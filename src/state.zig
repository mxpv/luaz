const std = @import("std");
const assert = std.debug.assert;
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
});

/// Get the current Lua VM clock time
pub fn clock() f64 {
    return c.lua_clock();
}

/// A low level Lua state wrapper providing access to Lua VM operations
pub const State = struct {
    lua: *c.lua_State,

    // Core Types
    pub const Number = f64;
    pub const Integer = c_int;
    pub const Unsigned = c_uint;
    pub const CFunction = *const fn (*c.lua_State) callconv(.C) c_int;
    pub const Continuation = *const fn (*c.lua_State, c_int) callconv(.C) c_int;
    pub const Alloc = *const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.C) ?*anyopaque;
    pub const Destructor = *const fn (*c.lua_State, ?*anyopaque) callconv(.C) void;
    pub const Vec = if (c.LUA_VECTOR_SIZE == 4) [4]f32 else [3]f32;

    // Constants
    pub const MULTRET = c.LUA_MULTRET;
    pub const REGISTRYINDEX = c.LUA_REGISTRYINDEX;
    pub const ENVIRONINDEX = c.LUA_ENVIRONINDEX;
    pub const GLOBALSINDEX = c.LUA_GLOBALSINDEX;

    // Enums
    pub const Status = enum(c_int) {
        ok = c.LUA_OK,
        yield = c.LUA_YIELD,
        errrun = c.LUA_ERRRUN,
        errsyntax = c.LUA_ERRSYNTAX,
        errmem = c.LUA_ERRMEM,
        errerr = c.LUA_ERRERR,
        break_debug = c.LUA_BREAK,
    };

    pub const CoStatus = enum(c_int) {
        run = c.LUA_CORUN,
        sus = c.LUA_COSUS,
        nor = c.LUA_CONOR,
        fin = c.LUA_COFIN,
        err = c.LUA_COERR,
    };

    pub const Type = enum(c_int) {
        none = c.LUA_TNONE,
        nil = c.LUA_TNIL,
        boolean = c.LUA_TBOOLEAN,
        lightuserdata = c.LUA_TLIGHTUSERDATA,
        number = c.LUA_TNUMBER,
        vector = c.LUA_TVECTOR,
        string = c.LUA_TSTRING,
        table = c.LUA_TTABLE,
        function = c.LUA_TFUNCTION,
        userdata = c.LUA_TUSERDATA,
        thread = c.LUA_TTHREAD,
        buffer = c.LUA_TBUFFER,
    };

    pub const GCOp = enum(c_int) {
        stop = c.LUA_GCSTOP,
        restart = c.LUA_GCRESTART,
        collect = c.LUA_GCCOLLECT,
        count = c.LUA_GCCOUNT,
        countb = c.LUA_GCCOUNTB,
        isrunning = c.LUA_GCISRUNNING,
        step = c.LUA_GCSTEP,
        setgoal = c.LUA_GCSETGOAL,
        setstepmul = c.LUA_GCSETSTEPMUL,
        setstepsize = c.LUA_GCSETSTEPSIZE,
    };

    // State Management

    /// Initialize a new Lua state with default allocator
    pub inline fn init() State {
        return State{
            .lua = c.luaL_newstate() orelse unreachable,
        };
    }

    /// Initialize a new Lua state with custom allocator
    pub inline fn initWithAlloc(alloc: Alloc, userdata: ?*anyopaque) ?State {
        const lua_state = c.lua_newstate(alloc, userdata);
        return if (lua_state) |state| State{ .lua = state } else null;
    }

    /// Clean up and close the Lua state
    pub inline fn deinit(self: State) void {
        c.lua_close(self.lua);
    }

    /// Creates a new thread, pushes it on the stack, and returns a pointer to a State that represents this new thread.
    /// The new thread returned by this function shares with the original thread its global environment,
    /// but has an independent execution stack.
    ///
    /// There is no explicit function to close or to destroy a thread.
    /// Threads are subject to garbage collection, like any Lua object.
    pub inline fn newThread(self: State) State {
        return State{ .lua = c.lua_newthread(self.lua) };
    }

    /// Get the main thread from any thread
    pub inline fn mainThread(self: State) State {
        return State{ .lua = c.lua_mainthread(self.lua) };
    }

    /// Reset a thread to its initial state
    pub inline fn resetThread(self: State) void {
        c.lua_resetthread(self.lua);
    }

    /// Check if thread is in reset state
    pub inline fn isThreadReset(self: State) bool {
        return c.lua_isthreadreset(self.lua) != 0;
    }

    // Stack Manipulation

    /// Convert a relative stack index to an absolute one
    pub inline fn absIndex(self: State, idx: i32) i32 {
        return c.lua_absindex(self.lua, idx);
    }

    /// Get the index of the top element in the stack
    pub inline fn getTop(self: State) i32 {
        return c.lua_gettop(self.lua);
    }

    /// Sets the top (that is, the number of elements in the stack) to a specific value.
    ///
    /// If the previous top was higher than the new one, the top values are discarded.
    /// Otherwise, the function pushes nils on the stack to get the given size.
    /// As a particular case, `lua_settop(L, 0)` empties the stack.
    ///
    /// Negative indices are also allowed to set the top element to the given index.
    ///
    /// See https://www.lua.org/pil/24.2.3.html
    pub inline fn setTop(self: State, idx: i32) void {
        c.lua_settop(self.lua, idx);
    }

    /// Pop n elements from the stack
    pub inline fn pop(self: State, n: i32) void {
        self.setTop(-(n) - 1);
    }

    /// Push a copy of the element at index idx onto the stack
    pub inline fn pushValue(self: State, idx: i32) void {
        c.lua_pushvalue(self.lua, idx);
    }

    /// Remove the element at index idx
    pub inline fn remove(self: State, idx: i32) void {
        c.lua_remove(self.lua, idx);
    }

    /// Insert the top element at index idx
    pub inline fn insert(self: State, idx: i32) void {
        c.lua_insert(self.lua, idx);
    }

    /// Replace the element at index idx with the top element
    pub inline fn replace(self: State, idx: i32) void {
        c.lua_replace(self.lua, idx);
    }

    /// Check if the stack can grow to accommodate sz more elements
    pub inline fn checkStack(self: State, sz: i32) bool {
        return c.lua_checkstack(self.lua, sz) != 0;
    }

    /// Ensure stack can grow (allows unlimited frames)
    pub inline fn rawCheckStack(self: State, sz: i32) void {
        c.lua_rawcheckstack(self.lua, sz);
    }

    /// Exchange values between different threads of the same state.
    ///
    /// This function pops `n` values from the stack `from`, and pushes them onto the stack `to`.
    pub inline fn xMove(from: State, to: State, n: i32) void {
        c.lua_xmove(from.lua, to.lua, n);
    }

    /// Push element at idx from one state to another
    pub inline fn xPush(from: State, to: State, idx: i32) void {
        c.lua_xpush(from.lua, to.lua, idx);
    }

    // Type Checking

    /// Check if value at index is a number
    pub inline fn isNumber(self: State, idx: i32) bool {
        return c.lua_isnumber(self.lua, idx) != 0;
    }

    /// Check if value at index is a string
    pub inline fn isString(self: State, idx: i32) bool {
        return c.lua_isstring(self.lua, idx) != 0;
    }

    /// Check if value at index is a C function
    pub inline fn isCFunction(self: State, idx: i32) bool {
        return c.lua_iscfunction(self.lua, idx) != 0;
    }

    /// Check if value at index is a Lua function
    pub inline fn isLFunction(self: State, idx: i32) bool {
        return c.lua_isLfunction(self.lua, idx) != 0;
    }

    /// Check if value at index is userdata
    pub inline fn isUserdata(self: State, idx: i32) bool {
        return c.lua_isuserdata(self.lua, idx) != 0;
    }

    /// Get the type of value at index
    pub inline fn getType(self: State, idx: i32) Type {
        return @enumFromInt(c.lua_type(self.lua, idx));
    }

    /// Get the type name for a given type
    pub inline fn typeName(self: State, tp: Type) [:0]const u8 {
        return std.mem.span(c.lua_typename(self.lua, @intFromEnum(tp)));
    }

    /// Check if value at index is a function
    pub inline fn isFunction(self: State, idx: i32) bool {
        return self.getType(idx) == .function;
    }

    /// Check if value at index is a table
    pub inline fn isTable(self: State, idx: i32) bool {
        return self.getType(idx) == .table;
    }

    /// Check if value at index is lightuserdata
    pub inline fn isLightUserdata(self: State, idx: i32) bool {
        return self.getType(idx) == .lightuserdata;
    }

    /// Check if value at index is nil
    pub inline fn isNil(self: State, idx: i32) bool {
        return self.getType(idx) == .nil;
    }

    /// Check if value at index is boolean
    pub inline fn isBoolean(self: State, idx: i32) bool {
        return self.getType(idx) == .boolean;
    }

    /// Check if value at index is vector
    pub inline fn isVector(self: State, idx: i32) bool {
        return self.getType(idx) == .vector;
    }

    /// Check if value at index is thread
    pub inline fn isThread(self: State, idx: i32) bool {
        return self.getType(idx) == .thread;
    }

    /// Check if value at index is buffer
    pub inline fn isBuffer(self: State, idx: i32) bool {
        return self.getType(idx) == .buffer;
    }

    /// Check if there's no value at index
    pub inline fn isNone(self: State, idx: i32) bool {
        return self.getType(idx) == .none;
    }

    /// Check if value at index is none or nil
    pub inline fn isNoneOrNil(self: State, idx: i32) bool {
        const t = self.getType(idx);
        return t == .none or t == .nil;
    }

    // Value Access

    /// Convert value at index to number, returns null if conversion failed
    pub inline fn toNumberX(self: State, idx: i32) ?Number {
        var isnum: i32 = 0;
        const result = c.lua_tonumberx(self.lua, idx, &isnum);
        return if (isnum != 0) result else null;
    }

    /// Convert value at index to number
    pub inline fn toNumber(self: State, idx: i32) Number {
        return c.lua_tonumber(self.lua, idx);
    }

    /// Convert value at index to integer, returns null if conversion failed
    pub inline fn toIntegerX(self: State, idx: i32) ?Integer {
        var isnum: i32 = 0;
        const result = c.lua_tointegerx(self.lua, idx, &isnum);
        return if (isnum != 0) result else null;
    }

    /// Convert value at index to integer
    pub inline fn toInteger(self: State, idx: i32) Integer {
        return c.lua_tointeger(self.lua, idx);
    }

    /// Convert value at index to unsigned integer, returns null if conversion failed
    pub inline fn toUnsignedX(self: State, idx: i32) ?Unsigned {
        var isnum: i32 = 0;
        const result = c.lua_tounsignedx(self.lua, idx, &isnum);
        return if (isnum != 0) result else null;
    }

    /// Convert value at index to unsigned integer
    pub inline fn toUnsigned(self: State, idx: i32) Unsigned {
        return c.lua_tounsigned(self.lua, idx);
    }

    /// Get vector value at index
    pub inline fn toVector(self: State, idx: i32) ?*const Vec {
        const ptr = c.lua_tovector(self.lua, idx);
        return if (ptr) |p| @ptrCast(p) else null;
    }

    /// Convert value at index to boolean
    pub inline fn toBoolean(self: State, idx: i32) bool {
        return c.lua_toboolean(self.lua, idx) != 0;
    }

    /// Convert value at index to string with length
    pub inline fn toLString(self: State, idx: i32, len: ?*usize) ?[:0]const u8 {
        const result = c.lua_tolstring(self.lua, idx, len);
        return if (result) |str| std.mem.span(str) else null;
    }

    /// Convert value at index to string
    pub inline fn toString(self: State, idx: i32) ?[:0]const u8 {
        return self.toLString(idx, null);
    }

    /// Get string atom at index
    pub inline fn toStringAtom(self: State, idx: c_int, atom: ?*c_int) ?[*:0]const u8 {
        return c.lua_tostringatom(self.lua, idx, atom);
    }

    /// Get string with length and atom at index
    pub inline fn toLStringAtom(self: State, idx: c_int, len: ?*usize, atom: ?*c_int) ?[*:0]const u8 {
        return c.lua_tolstringatom(self.lua, idx, len, atom);
    }

    /// Get namecall atom
    pub inline fn nameCallAtom(self: State, atom: ?*c_int) ?[*:0]const u8 {
        return c.lua_namecallatom(self.lua, atom);
    }

    /// Get object length at index
    pub inline fn objLen(self: State, idx: c_int) c_int {
        return c.lua_objlen(self.lua, idx);
    }

    /// Get C function at index
    pub inline fn toCFunction(self: State, idx: c_int) ?CFunction {
        return c.lua_tocfunction(self.lua, idx);
    }

    /// Get light userdata at index
    pub inline fn toLightUserdata(self: State, idx: c_int) ?*anyopaque {
        return c.lua_tolightuserdata(self.lua, idx);
    }

    /// Get tagged light userdata at index
    pub inline fn toLightUserdataTagged(self: State, idx: c_int, tag: c_int) ?*anyopaque {
        return c.lua_tolightuserdatatagged(self.lua, idx, tag);
    }

    /// Get userdata at index
    pub inline fn toUserdata(self: State, idx: c_int) ?*anyopaque {
        return c.lua_touserdata(self.lua, idx);
    }

    /// Get tagged userdata at index
    pub inline fn toUserdataTagged(self: State, idx: c_int, tag: c_int) ?*anyopaque {
        return c.lua_touserdatatagged(self.lua, idx, tag);
    }

    /// Get userdata tag at index
    pub inline fn userdataTag(self: State, idx: c_int) c_int {
        return c.lua_userdatatag(self.lua, idx);
    }

    /// Get light userdata tag at index
    pub inline fn lightUserdataTag(self: State, idx: c_int) c_int {
        return c.lua_lightuserdatatag(self.lua, idx);
    }

    /// Get thread at index
    pub inline fn toThread(self: State, idx: c_int) ?State {
        const thread = c.lua_tothread(self.lua, idx);
        return if (thread) |t| State{ .lua = t } else null;
    }

    /// Get buffer at index
    pub inline fn toBuffer(self: State, idx: c_int, len: ?*usize) ?*anyopaque {
        return c.lua_tobuffer(self.lua, idx, len);
    }

    /// Get pointer representation of value at index
    pub inline fn toPointer(self: State, idx: c_int) ?*const anyopaque {
        return c.lua_topointer(self.lua, idx);
    }

    // Push Functions

    /// Push nil onto the stack
    pub inline fn pushNil(self: State) void {
        c.lua_pushnil(self.lua);
    }

    /// Push a number onto the stack
    pub inline fn pushNumber(self: State, n: Number) void {
        c.lua_pushnumber(self.lua, n);
    }

    /// Push an integer onto the stack
    pub inline fn pushInteger(self: State, n: Integer) void {
        c.lua_pushinteger(self.lua, n);
    }

    /// Push an unsigned integer onto the stack
    pub inline fn pushUnsigned(self: State, n: Unsigned) void {
        c.lua_pushunsigned(self.lua, n);
    }

    /// Push a vector onto the stack
    pub inline fn pushVector(self: State, x: f32, y: f32, z: f32, w: f32) void {
        if (c.LUA_VECTOR_SIZE == 4) {
            c.lua_pushvector(self.lua, x, y, z, w);
        } else {
            c.lua_pushvector(self.lua, x, y, z);
        }
    }

    /// Push a string slice onto the stack
    pub inline fn pushLString(self: State, s: []const u8) void {
        c.lua_pushlstring(self.lua, s.ptr, s.len);
    }

    /// Push a null-terminated string onto the stack
    pub inline fn pushString(self: State, s: [:0]const u8) void {
        c.lua_pushstring(self.lua, s.ptr);
    }

    /// Push a formatted string onto the stack
    pub inline fn pushFString(self: State, fmt: [*:0]const u8, args: anytype) [*:0]const u8 {
        return c.lua_pushfstringL(self.lua, fmt, args);
    }

    /// Push a C closure onto the stack
    pub inline fn pushCClosureK(self: State, func: CFunction, debugname: ?[*:0]const u8, nup: c_int, cont: ?Continuation) void {
        c.lua_pushcclosurek(self.lua, func, debugname, nup, cont);
    }

    /// Push a C function onto the stack
    pub inline fn pushCFunction(self: State, func: CFunction, debugname: ?[*:0]const u8) void {
        self.pushCClosureK(func, debugname, 0, null);
    }

    /// Pushes a new C closure onto the stack.
    ///
    /// When a C function is created, it is possible to associate some values with it, thus creating a C closure,
    /// these values are then accessible to the function whenever it is called.
    ///
    /// To associate values with a C function, first these values should be pushed onto the stack (when there are
    /// multiple values, the first value is pushed first).
    ///
    /// Then `lua_pushcclosure` is called to create and push the C function onto the stack, with the argument `n`
    /// telling how many values should be associated with the function.
    ///
    /// `lua_pushcclosure` also pops these values from the stack.
    pub inline fn pushCClosure(self: State, func: CFunction, debugname: ?[*:0]const u8, n: c_int) void {
        assert(n < 256);
        self.pushCClosureK(func, debugname, n, null);
    }

    /// Push a boolean onto the stack
    pub inline fn pushBoolean(self: State, b: bool) void {
        c.lua_pushboolean(self.lua, if (b) 1 else 0);
    }

    /// Push the current thread onto the stack
    pub inline fn pushThread(self: State) bool {
        return c.lua_pushthread(self.lua) != 0;
    }

    /// Pushes a light userdata onto the stack.
    ///
    /// Userdata represent C values in Lua. A light userdata represents a pointer.
    /// It is a value (like a number): you do not create it, it has no individual metatable,
    /// and it is not collected (as it was never created).
    ///
    /// A light userdata is equal to "any" light userdata with the same C address.
    ///
    /// See <https://www.lua.org/pil/28.5.html>
    pub inline fn pushLightUserdataTagged(self: State, p: *anyopaque, tag: i32) void {
        c.lua_pushlightuserdatatagged(self.lua, p, tag);
    }

    /// Push light userdata onto the stack
    pub inline fn pushLightUserdata(self: State, p: *anyopaque) void {
        self.pushLightUserdataTagged(p, 0);
    }

    /// Create new tagged userdata
    pub inline fn newUserdataTagged(self: State, size: usize, tag: c_int) ?*anyopaque {
        return c.lua_newuserdatatagged(self.lua, size, tag);
    }

    /// Create new userdata
    pub inline fn newUserdata(self: State, size: usize) ?*anyopaque {
        return self.newUserdataTagged(size, 0);
    }

    /// Create new tagged userdata with metatable
    pub inline fn newUserdataTaggedWithMetatable(self: State, size: usize, tag: c_int) ?*anyopaque {
        return c.lua_newuserdatataggedwithmetatable(self.lua, size, tag);
    }

    /// Create new userdata with destructor
    pub inline fn newUserdataDtor(self: State, size: usize, dtor: *const fn (?*anyopaque) callconv(.C) void) ?*anyopaque {
        return c.lua_newuserdatadtor(self.lua, size, dtor);
    }

    /// Create new buffer
    pub inline fn newBuffer(self: State, size: usize) ?*anyopaque {
        return c.lua_newbuffer(self.lua, size);
    }

    // Table Operations

    /// Pushes onto the stack the value `t[k]`, where `t` is the value at the given index and `k` is the value
    /// at the top of the stack.
    ///
    /// This function pops the key from the stack, pushing the resulting value in its place.
    /// As in Lua, this function may trigger a metamethod for the "index" event.
    ///
    /// For instance, to get a value stored with key "Key" in the registry, you can use the following code:
    /// ```zig
    /// state.pushString("Key");
    /// _ = state.getTable(State.REGISTRYINDEX);
    /// ```
    ///
    /// See <https://www.lua.org/pil/25.1.html>
    pub inline fn getTable(self: State, idx: c_int) Type {
        return @enumFromInt(c.lua_gettable(self.lua, idx));
    }

    /// Get field from table and push onto stack
    ///
    /// Pushes onto the stack the value t[k], where t is the value at the given index.
    /// As in Lua, this function may trigger a metamethod for the "index" event
    pub inline fn getField(self: State, idx: i32, k: [:0]const u8) Type {
        return @enumFromInt(c.lua_getfield(self.lua, idx, k.ptr));
    }

    /// Raw get field from table
    pub inline fn rawGetField(self: State, idx: i32, k: [:0]const u8) Type {
        return @enumFromInt(c.lua_rawgetfield(self.lua, idx, k.ptr));
    }

    /// Raw get from table
    pub inline fn rawGet(self: State, idx: i32) Type {
        return @enumFromInt(c.lua_rawget(self.lua, idx));
    }

    /// Pushes onto the stack the value `t[n]`, where `t` is the table at the given index.
    /// The access is raw, that is, it does not invoke the `__index` metamethod.
    ///
    /// Arguments:
    /// - `idx`: Refers to where the table is in the stack.
    /// - `n`:  Refers to where the element is in the table.
    ///
    /// Returns the type of the pushed value.
    pub inline fn rawGetI(self: State, idx: i32, n: i32) Type {
        return @enumFromInt(c.lua_rawgeti(self.lua, idx, n));
    }

    /// Creates a new empty table and pushes it onto the stack.
    ///
    /// Parameter `narr` is a hint for how many elements the table will have as a sequence;
    /// parameter `nrec` is a hint for how many other elements the table will have.
    /// Lua may use these hints to preallocate memory for the new table.
    pub inline fn createTable(self: State, narr: u32, nrec: u32) void {
        c.lua_createtable(self.lua, @intCast(narr), @intCast(nrec));
    }

    /// Create a new empty table
    pub inline fn newTable(self: State) void {
        self.createTable(0, 0);
    }

    /// Set table readonly state
    pub inline fn setReadonly(self: State, idx: c_int, enabled: bool) void {
        c.lua_setreadonly(self.lua, idx, if (enabled) 1 else 0);
    }

    /// Get table readonly state
    pub inline fn getReadonly(self: State, idx: c_int) bool {
        return c.lua_getreadonly(self.lua, idx) != 0;
    }

    /// Set table safe environment
    pub inline fn setSafeEnv(self: State, idx: c_int, enabled: bool) void {
        c.lua_setsafeenv(self.lua, idx, if (enabled) 1 else 0);
    }

    /// Get metatable and push onto stack
    pub inline fn getMetatable(self: State, objindex: c_int) bool {
        return c.lua_getmetatable(self.lua, objindex) != 0;
    }

    /// Get function environment
    pub inline fn getFEnv(self: State, idx: c_int) void {
        c.lua_getfenv(self.lua, idx);
    }

    /// Set table value from stack
    ///
    /// Does the equivalent to `t[k] = v`, where `t` is the value at the given index,
    /// `v` is the value at the top of the stack, and k is the value just below the top.
    ///
    /// This function pops both the key and the value from the stack.
    /// As in Lua, this function may trigger a metamethod for the "newindex" event.
    ///
    /// The following code shows how to store and retrieve a number from the registry using this method:
    /// ```zig
    /// const key: u8 = 'k'; // Variable with a unique address
    ///
    /// state.pushLightUserdata(@ptrCast(&key)); // Push address
    /// state.pushNumber(myNumber); // Push value
    ///
    /// state.setTable(State.REGISTRYINDEX); // E.g. registry[&key] = myNumber
    /// ```
    ///
    /// See <https://www.lua.org/pil/25.1.html>
    pub inline fn setTable(self: State, idx: i32) void {
        c.lua_settable(self.lua, idx);
    }

    /// Set field in table from stack top
    ///
    /// Does the equivalent to t[k] = v, where t is the value at the given valid index and v is the value at the top
    /// of the stack.
    ///
    /// This function pops the value from the stack.
    pub inline fn setField(self: State, idx: i32, k: [:0]const u8) void {
        c.lua_setfield(self.lua, idx, k.ptr);
    }

    /// Raw set field in table
    pub inline fn rawSetField(self: State, idx: i32, k: [:0]const u8) void {
        c.lua_rawsetfield(self.lua, idx, k.ptr);
    }

    /// Raw set in table
    pub inline fn rawSet(self: State, idx: i32) void {
        c.lua_rawset(self.lua, idx);
    }

    /// Raw set by integer index
    ///
    /// Does the equivalent of `t[i] = v`, where `t` is the table at the given `idx` and `v` is the value
    /// at the top of the stack. This function pops the value from the stack.
    ///
    /// Arguments:
    /// - `idx`: Refers to where the table is in the stack.
    /// - `n`:  Refers to where the element is in the table.
    ///
    /// The assignment is raw, that is, it does not invoke the `__newindex` metamethod.
    ///
    /// Note: This is rawSetI, not rawGetI. The equivalent rawGet sequence would be:
    /// ```zig
    /// state.pushNumber(@floatFromInt(key));
    /// _ = state.rawGet(t);
    /// ```
    /// See <https://www.lua.org/pil/27.1.html>
    pub inline fn rawSetI(self: State, idx: i32, n: i32) void {
        c.lua_rawseti(self.lua, idx, n);
    }

    /// Set metatable
    pub inline fn setMetatable(self: State, objindex: i32) bool {
        return c.lua_setmetatable(self.lua, objindex) != 0;
    }

    /// Set function environment
    pub inline fn setFEnv(self: State, idx: i32) bool {
        return c.lua_setfenv(self.lua, idx) != 0;
    }

    /// Set global variable
    pub inline fn setGlobal(self: State, name: [*:0]const u8) void {
        self.setField(GLOBALSINDEX, name);
    }

    /// Get global variable
    pub inline fn getGlobal(self: State, name: [*:0]const u8) Type {
        return self.getField(GLOBALSINDEX, name);
    }

    // Load and Call

    /// Load Luau bytecode
    pub inline fn load(self: State, chunkname: [*:0]const u8, data: [*]const u8, size: usize, env: c_int) Status {
        return @enumFromInt(c.luau_load(self.lua, chunkname, data, size, env));
    }

    /// Call a function
    pub inline fn call(self: State, nargs: u32, nresults: i32) void {
        c.lua_call(self.lua, @intCast(nargs), nresults);
    }

    /// Calls a function.
    ///
    /// To call a function you must use the following protocol:
    /// - The function to be called is pushed onto the stack.
    /// - The arguments to the function are pushed in direct order (the first argument is pushed first).
    /// - Finally `lua_pcall` is invoked.
    ///
    /// All arguments and the function value are popped from the stack when the function is called.
    pub inline fn pcall(self: State, nargs: u32, nresults: i32, errfunc: i32) Status {
        return @enumFromInt(c.lua_pcall(self.lua, @intCast(nargs), nresults, errfunc));
    }

    // Coroutine Operations

    /// Yield from coroutine
    pub inline fn yield(self: State, nresults: u32) Status {
        return @enumFromInt(c.lua_yield(self.lua, @intCast(nresults)));
    }

    /// Break execution
    pub inline fn break_(self: State) Status {
        return @enumFromInt(c.lua_break(self.lua));
    }

    /// Resume coroutine
    pub inline fn resume_(self: State, from: ?State, narg: u32) Status {
        const from_lua = if (from) |f| f.lua else null;
        return @enumFromInt(c.lua_resume(self.lua, from_lua, @intCast(narg)));
    }

    /// Resume with error
    pub inline fn resumeError(self: State, from: ?State) Status {
        const from_lua = if (from) |f| f.lua else null;
        return @enumFromInt(c.lua_resumeerror(self.lua, from_lua));
    }

    /// Get coroutine status
    pub inline fn status(self: State) Status {
        return @enumFromInt(c.lua_status(self.lua));
    }

    /// Check if coroutine is yieldable
    pub inline fn isYieldable(self: State) bool {
        return c.lua_isyieldable(self.lua) != 0;
    }

    /// Get thread data
    pub inline fn getThreadData(self: State) ?*anyopaque {
        return c.lua_getthreaddata(self.lua);
    }

    /// Set thread data
    pub inline fn setThreadData(self: State, data: ?*anyopaque) void {
        c.lua_setthreaddata(self.lua, data);
    }

    /// Get coroutine status relative to another
    pub inline fn coStatus(self: State, co: State) CoStatus {
        return @enumFromInt(c.lua_costatus(self.lua, co.lua));
    }

    // Garbage Collection

    /// Control garbage collector
    ///
    /// Luau uses an incremental garbage collector which does a little bit of work every so often,
    /// and at no point does it stop the world to traverse the entire heap.
    ///
    /// See <https://luau.org/performance#improved-garbage-collector-pacing> and
    /// <https://www.lua.org/manual/5.2/manual.html#lua_gc>
    pub inline fn gc(self: State, what: GCOp, data: i32) i32 {
        return c.lua_gc(self.lua, @intFromEnum(what), data);
    }

    // Memory Management

    /// Set memory category for allocations
    pub inline fn setMemCat(self: State, category: u8) void {
        c.lua_setmemcat(self.lua, @intCast(category));
    }

    /// Get total bytes allocated in category
    pub inline fn totalBytes(self: State, category: u8) usize {
        return c.lua_totalbytes(self.lua, @intCast(category));
    }

    /// Get allocator function
    pub inline fn getAllocF(self: State, ud: ?*?*anyopaque) Alloc {
        return c.lua_getallocf(self.lua, ud);
    }

    // Miscellaneous

    /// Raise an error
    pub inline fn raiseError(self: State) noreturn {
        c.lua_error(self.lua);
    }

    /// Table iteration
    ///
    /// Pops a key from the stack, and pushes a key–value pair from the table at the given index (the "next" pair
    /// after the given key).
    ///
    /// If there are no more elements in the table, then `lua_next` returns 0 (and pushes nothing).
    pub inline fn next(self: State, idx: i32) bool {
        return c.lua_next(self.lua, idx) != 0;
    }

    /// Raw table iteration
    pub inline fn rawIter(self: State, idx: i32, iter: i32) i32 {
        return c.lua_rawiter(self.lua, idx, iter);
    }

    /// Concatenate values on stack
    pub inline fn concat(self: State, n: u32) void {
        c.lua_concat(self.lua, @intCast(n));
    }

    /// Encode pointer for security
    pub inline fn encodePointer(self: State, p: usize) usize {
        return c.lua_encodepointer(self.lua, p);
    }

    // Comparison Operations

    /// Check equality of two values
    pub inline fn equal(self: State, idx1: i32, idx2: i32) bool {
        return c.lua_equal(self.lua, idx1, idx2) != 0;
    }

    /// Raw equality check (no metamethods)
    pub inline fn rawEqual(self: State, idx1: i32, idx2: i32) bool {
        return c.lua_rawequal(self.lua, idx1, idx2) != 0;
    }

    /// Less than comparison
    pub inline fn lessThan(self: State, idx1: i32, idx2: i32) bool {
        return c.lua_lessthan(self.lua, idx1, idx2) != 0;
    }

    // Reference System

    /// Create a reference to object at index
    ///
    /// Creates and returns a reference, in the table at index t,
    /// for the object at the top of the stack (and pops the object).
    ///
    /// The call:
    /// ```zig
    /// const r = state.ref(-1);
    /// ```
    ///
    /// pops a value from the stack, stores it into the registry with a fresh integer key,
    /// and returns that key.
    ///
    /// See <https://github.com/luau-lang/luau/issues/247>
    pub inline fn ref(self: State, idx: i32) i32 {
        return c.lua_ref(self.lua, idx);
    }

    /// Releases reference `r` from the table at index t.
    ///
    /// The entry is removed from the table, so that the referred object can be collected.
    /// The reference `r` is also freed to be used again.
    pub inline fn unref(self: State, ref_id: i32) void {
        c.lua_unref(self.lua, ref_id);
    }

    /// Get value from reference
    pub inline fn getRef(self: State, ref_id: i32) Type {
        return self.rawGetI(REGISTRYINDEX, ref_id);
    }

    // Userdata Operations

    /// Set userdata tag
    pub inline fn setUserdataTag(self: State, idx: i32, tag: i32) void {
        c.lua_setuserdatatag(self.lua, idx, tag);
    }

    /// Set userdata destructor for tag
    pub inline fn setUserdataDtor(self: State, tag: i32, dtor: Destructor) void {
        c.lua_setuserdatadtor(self.lua, tag, dtor);
    }

    /// Get userdata destructor for tag
    pub inline fn getUserdataDtor(self: State, tag: i32) ?Destructor {
        return c.lua_getuserdatadtor(self.lua, tag);
    }

    /// Set userdata metatable for tag
    pub inline fn setUserdataMetatable(self: State, tag: i32) void {
        c.lua_setuserdatametatable(self.lua, tag);
    }

    /// Get userdata metatable for tag
    pub inline fn getUserdataMetatable(self: State, tag: i32) void {
        c.lua_getuserdatametatable(self.lua, tag);
    }

    /// Set light userdata name for tag
    pub inline fn setLightUserdataName(self: State, tag: i32, name: [:0]const u8) void {
        c.lua_setlightuserdataname(self.lua, tag, name.ptr);
    }

    /// Get light userdata name for tag
    pub inline fn getLightUserdataName(self: State, tag: i32) ?[:0]const u8 {
        const result = c.lua_getlightuserdataname(self.lua, tag);
        return if (result) |str| std.mem.span(str) else null;
    }

    // Function Operations

    /// Clone function at index
    pub inline fn cloneFunction(self: State, idx: i32) void {
        c.lua_clonefunction(self.lua, idx);
    }

    // Table Utilities

    /// Clear all entries from table
    pub inline fn clearTable(self: State, idx: i32) void {
        c.lua_cleartable(self.lua, idx);
    }

    /// Clone table at index
    pub inline fn cloneTable(self: State, idx: i32) void {
        c.lua_clonetable(self.lua, idx);
    }

    // Utility macros as inline functions

    /// When a C function is created, it is possible to associate some values with it, thus creating a C closure;
    /// these values are called upvalues and are accessible to the function whenever it is called.
    ///
    /// Whenever a C function is called, its upvalues are located at specific pseudo-indices.
    /// These pseudo-indices are produced by the macro `lua_upvalueindex`.
    ///
    /// The first upvalue associated with a function is at index lua_upvalueindex(1), and so on.
    /// Any access to lua_upvalueindex(n), where n is greater than the number of upvalues of the current function
    /// (but not greater than 256, which is one plus the maximum number of upvalues in a closure),
    /// produces an acceptable but invalid index.
    pub inline fn upvalueIndex(i: i32) i32 {
        assert(i < 256);
        return GLOBALSINDEX - i;
    }

    /// Check if index is pseudo-index
    pub inline fn isPseudo(i: i32) bool {
        return i <= REGISTRYINDEX;
    }

    // Lua Auxiliary Library Functions (lualib.h)

    /// Register library functions
    pub inline fn register(self: State, libname: ?[:0]const u8, funcs: []const c.luaL_Reg) void {
        const name_ptr = if (libname) |name| name.ptr else null;
        c.luaL_register(self.lua, name_ptr, funcs.ptr);
    }

    /// Get metafield and push onto stack
    pub inline fn getMetafield(self: State, obj: i32, field: [:0]const u8) bool {
        return c.luaL_getmetafield(self.lua, obj, field.ptr) != 0;
    }

    /// Call metamethod
    pub inline fn callMeta(self: State, obj: i32, field: [:0]const u8) bool {
        return c.luaL_callmeta(self.lua, obj, field.ptr) != 0;
    }

    /// Raise type error (does not return)
    pub inline fn typeError(self: State, narg: i32, tname: [:0]const u8) noreturn {
        c.luaL_typeerrorL(self.lua, narg, tname.ptr);
    }

    /// Raise argument error (does not return)
    ///
    /// Raises an error reporting a problem with argument narg of the C function that called it,
    /// using a standard message that includes extramsg as a comment:
    /// ```
    ///     bad argument #narg to 'funcname' (extramsg)
    /// ```
    ///
    /// This function never returns.
    pub inline fn argError(self: State, narg: i32, extramsg: [:0]const u8) noreturn {
        c.luaL_argerrorL(self.lua, narg, extramsg.ptr);
    }

    /// Check and get string argument
    pub inline fn checkLString(self: State, narg: i32, len: ?*usize) [:0]const u8 {
        const result = c.luaL_checklstring(self.lua, narg, len);
        return std.mem.span(result);
    }

    /// Check and get string argument (without length)
    pub inline fn checkString(self: State, narg: i32) [:0]const u8 {
        return self.checkLString(narg, null);
    }

    /// Get optional string argument
    pub inline fn optLString(self: State, narg: i32, def: [:0]const u8, len: ?*usize) [:0]const u8 {
        const result = c.luaL_optlstring(self.lua, narg, def.ptr, len);
        return std.mem.span(result);
    }

    /// Get optional string argument (without length)
    pub inline fn optString(self: State, narg: i32, def: [:0]const u8) [:0]const u8 {
        return self.optLString(narg, def, null);
    }

    /// Check and get number argument
    pub inline fn checkNumber(self: State, narg: i32) Number {
        return c.luaL_checknumber(self.lua, narg);
    }

    /// Get optional number argument
    pub inline fn optNumber(self: State, narg: i32, def: Number) Number {
        return c.luaL_optnumber(self.lua, narg, def);
    }

    /// Check and get boolean argument
    pub inline fn checkBoolean(self: State, narg: i32) bool {
        return c.luaL_checkboolean(self.lua, narg) != 0;
    }

    /// Get optional boolean argument
    pub inline fn optBoolean(self: State, narg: i32, def: bool) bool {
        return c.luaL_optboolean(self.lua, narg, if (def) 1 else 0) != 0;
    }

    /// Check and get integer argument
    pub inline fn checkInteger(self: State, narg: i32) Integer {
        return c.luaL_checkinteger(self.lua, narg);
    }

    /// Get optional integer argument
    pub inline fn optInteger(self: State, narg: i32, def: Integer) Integer {
        return c.luaL_optinteger(self.lua, narg, def);
    }

    /// Check and get unsigned integer argument
    pub inline fn checkUnsigned(self: State, narg: i32) Unsigned {
        return c.luaL_checkunsigned(self.lua, narg);
    }

    /// Get optional unsigned integer argument
    pub inline fn optUnsigned(self: State, narg: i32, def: Unsigned) Unsigned {
        return c.luaL_optunsigned(self.lua, narg, def);
    }

    /// Check and get vector argument
    pub inline fn checkVector(self: State, narg: i32) *const Vec {
        const ptr = c.luaL_checkvector(self.lua, narg);
        return @ptrCast(ptr);
    }

    /// Get optional vector argument
    pub inline fn optVector(self: State, narg: i32, def: *const Vec) *const Vec {
        const ptr = c.luaL_optvector(self.lua, narg, @ptrCast(def));
        return @ptrCast(ptr);
    }

    /// Check stack space with message
    pub inline fn checkStackMsg(self: State, sz: i32, msg: [:0]const u8) void {
        c.luaL_checkstack(self.lua, sz, msg.ptr);
    }

    /// Check argument type
    pub inline fn checkType(self: State, narg: i32, t: Type) void {
        c.luaL_checktype(self.lua, narg, @intFromEnum(t));
    }

    /// Check that argument exists
    pub inline fn checkAny(self: State, narg: i32) void {
        c.luaL_checkany(self.lua, narg);
    }

    /// Create new metatable
    pub inline fn newMetatable(self: State, tname: [:0]const u8) bool {
        return c.luaL_newmetatable(self.lua, tname.ptr) != 0;
    }

    /// Check userdata with metatable
    pub inline fn checkUdata(self: State, ud: i32, tname: [:0]const u8) *anyopaque {
        return c.luaL_checkudata(self.lua, ud, tname.ptr).?;
    }

    /// Check buffer argument
    pub inline fn checkBuffer(self: State, narg: i32, len: *usize) *anyopaque {
        return c.luaL_checkbuffer(self.lua, narg, len).?;
    }

    /// Push error location info
    pub inline fn where(self: State, lvl: i32) void {
        c.luaL_where(self.lua, lvl);
    }

    /// Convert value to string and push
    pub inline fn tolString(self: State, idx: i32, len: ?*usize) [:0]const u8 {
        const result = c.luaL_tolstring(self.lua, idx, len);
        return std.mem.span(result);
    }

    /// Find table in registry
    pub inline fn findTable(self: State, idx: i32, fname: [:0]const u8, szhint: i32) ?[:0]const u8 {
        const result = c.luaL_findtable(self.lua, idx, fname.ptr, szhint);
        return if (result) |str| std.mem.span(str) else null;
    }

    /// Get type name of value at index
    pub inline fn luaTypeName(self: State, idx: i32) [:0]const u8 {
        const result = c.luaL_typename(self.lua, idx);
        return std.mem.span(result);
    }

    /// Call function from yieldable C function
    pub inline fn callYieldable(self: State, nargs: u32, nresults: i32) i32 {
        return c.luaL_callyieldable(self.lua, @intCast(nargs), nresults);
    }

    // String Buffer Operations

    /// Initialize string buffer
    pub inline fn bufInit(self: State, buf: *c.luaL_Strbuf) void {
        c.luaL_buffinit(self.lua, buf);
    }

    /// Initialize string buffer with size
    pub inline fn bufInitSize(self: State, buf: *c.luaL_Strbuf, size: usize) []u8 {
        const ptr = c.luaL_buffinitsize(self.lua, buf, size);
        return ptr[0..size];
    }

    /// Prepare buffer with size
    pub inline fn prepBuffSize(buf: *c.luaL_Strbuf, size: usize) []u8 {
        const ptr = c.luaL_prepbuffsize(buf, size);
        return ptr[0..size];
    }

    /// Add string to buffer
    pub inline fn addLString(buf: *c.luaL_Strbuf, s: []const u8) void {
        c.luaL_addlstring(buf, s.ptr, s.len);
    }

    /// Add value from stack to buffer
    pub inline fn addValue(buf: *c.luaL_Strbuf) void {
        c.luaL_addvalue(buf);
    }

    /// Add value at index to buffer
    pub inline fn addValueAny(buf: *c.luaL_Strbuf, idx: i32) void {
        c.luaL_addvalueany(buf, idx);
    }

    /// Push buffer result to stack
    pub inline fn pushResult(buf: *c.luaL_Strbuf) void {
        c.luaL_pushresult(buf);
    }

    /// Push buffer result with size to stack
    pub inline fn pushResultSize(buf: *c.luaL_Strbuf, size: usize) void {
        c.luaL_pushresultsize(buf, size);
    }

    // Library Loading Functions

    /// Open base library
    pub inline fn openBase(self: State) i32 {
        return c.luaopen_base(self.lua);
    }

    /// Open coroutine library
    pub inline fn openCoroutine(self: State) i32 {
        return c.luaopen_coroutine(self.lua);
    }

    /// Open table library
    pub inline fn openTable(self: State) i32 {
        return c.luaopen_table(self.lua);
    }

    /// Open os library
    pub inline fn openOs(self: State) i32 {
        return c.luaopen_os(self.lua);
    }

    /// Open string library
    pub inline fn openString(self: State) i32 {
        return c.luaopen_string(self.lua);
    }

    /// Open bit32 library
    pub inline fn openBit32(self: State) i32 {
        return c.luaopen_bit32(self.lua);
    }

    /// Open buffer library
    pub inline fn openBuffer(self: State) i32 {
        return c.luaopen_buffer(self.lua);
    }

    /// Open utf8 library
    pub inline fn openUtf8(self: State) i32 {
        return c.luaopen_utf8(self.lua);
    }

    /// Open math library
    pub inline fn openMath(self: State) i32 {
        return c.luaopen_math(self.lua);
    }

    /// Open debug library
    pub inline fn openDebug(self: State) i32 {
        return c.luaopen_debug(self.lua);
    }

    /// Open vector library
    pub inline fn openVector(self: State) i32 {
        return c.luaopen_vector(self.lua);
    }

    /// Open all standard libraries
    pub inline fn openLibs(self: State) void {
        c.luaL_openlibs(self.lua);
    }

    /// Apply sandbox restrictions
    pub inline fn sandbox(self: State) void {
        c.luaL_sandbox(self.lua);
    }

    /// Apply sandbox restrictions to thread
    pub inline fn sandboxThread(self: State) void {
        c.luaL_sandboxthread(self.lua);
    }

    // Utility Functions

    /// Check argument condition
    pub inline fn argCheck(self: State, cond: bool, arg: i32, extramsg: [:0]const u8) void {
        if (!cond) self.argError(arg, extramsg);
    }

    /// Check expected argument type
    pub inline fn argExpected(self: State, cond: bool, arg: i32, tname: [:0]const u8) void {
        if (!cond) self.typeError(arg, tname);
    }
};

const expect = std.testing.expect;

test clock {
    try expect(clock() > 0.0);
}

test "Basic stack ops" {
    const state = State.init();
    defer state.deinit();

    try expect(state.getTop() == 0);

    state.pushNumber(11);
    try expect(state.getTop() == 1);

    state.pushBoolean(true);
    try expect(state.getTop() == 2);

    state.setTop(0);
    try expect(state.getTop() == 0);
}
