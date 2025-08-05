<p align="center">
  <img src="docs/logo.png" />
</p>

# luaz

[![CI](https://github.com/mxpv/luaz/actions/workflows/ci.yml/badge.svg)](https://github.com/mxpv/luaz/actions/workflows/ci.yml)
[![Docs](https://github.com/mxpv/luaz/actions/workflows/docs.yml/badge.svg)](https://github.com/mxpv/luaz/actions/workflows/docs.yml)
[![GitHub License](https://img.shields.io/github/license/mxpv/luaz)](./LICENSE)
[![codecov](https://codecov.io/gh/mxpv/luaz/branch/main/graph/badge.svg?token=GUTOF5TGFQ)](https://codecov.io/gh/mxpv/luaz)

`luaz` is a zero-cost wrapper library for [`Luau`](https://github.com/luau-lang/luau).
Unlike other libraries, it focuses specifically on `Luau`, providing idiomatic `Zig` bindings that leverage Luau's [unique features](https://luau.org/why)
and [performance](https://luau.org/performance) characteristics.

The build system provides prebuilt Luau tools out of the box:
- [`luau-compiler`](#compiler): Compile Luau source to bytecode
- [`luau-analyzer`](#analyzer): Typecheck and lint Luau code

These tools make it easy to compile, analyze, and embed `Luau` scripts directly into your Zig applications.

## ✨ Features

- Minimal yet flexible zero-cost [API](#basic-usage)
- Bidirectional [function calls](#function-calls) between Zig and Lua
- First-class [userdata support](#userdata-integration) including metamethods
- Native support for refs, functions, tables, and vector types
- Supports Luau code generation for improved performance on supported platforms
- Built-in [Luau tools](#-using-luau-tools) (`luau-compile` and `luau-analyze`) provided by the build system
- Excellent test coverage and API [documentation](https://mxpv.github.io/luaz/#luaz.lua)

## 📚 Documentation

Full API documentation is available at: https://mxpv.github.io/luaz/#luaz.lua

The documentation is automatically updated on every change to the `main` branch.

> [!TIP]
> For a comprehensive overview of all features, see the [guided tour example](examples/guided_tour.zig) which can be run with `zig build guided-tour`.

### Basic Usage

The following example demonstrates some basic use cases.

- `Lua` takes optional Zig allocator.
- Global table `_G` is available via `globals()` table.
- `eval` is a helper function that compiles Lua code to Luau bytecode and executes it.
- `set` and `get` are used to pass and retrieve data.

```zig
const std = @import("std");
const luaz = @import("luaz");
const assert = std.debug.assert;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var lua = try luaz.Lua.init(&gpa.allocator); // Create Lua state with custom allocator
    defer lua.deinit(); // Clean up Lua state

    // Set a global variable
    try lua.globals().set("greeting", "Hello from Zig!");

    // Get and verify the global variable
    const value = try lua.globals().get("greeting", []const u8);
    assert(std.mem.eql(u8, value.?, "Hello from Zig!"));

    // Evaluate Lua code and get result
    const result = try lua.eval("return 2 + 3 * 4", .{}, i32);
    assert(result == 14);
}
```

> [!NOTE]
> Ideally, the bundled  `luau-compile` tool should be used to precompile Lua scripts offline.

### Function Calls

Both Lua functions can be called from Zig and Zig functions from Lua with automatic type conversion and argument 
handling.

```zig
const std = @import("std");
const luaz = @import("luaz");
const assert = std.debug.assert;

fn sum(a: i32, b: i32) i32 {
    return a + b;
}

pub fn main() !void {
    var lua = try luaz.Lua.init(null); // Use default allocator
    defer lua.deinit();

    // Register Zig function in Lua
    try lua.globals().set("sum", sum);

    // Call Zig function from Lua
    const result1 = try lua.eval("return sum(10, 20)", .{}, i32);
    assert(result1 == 30);

    // Define Lua function
    _ = try lua.eval("function multiply(x, y) return x * y end", .{}, void);

    // Call Lua function from Zig
    const result2 = try lua.globals().call("multiply", .{6, 7}, i32);
    assert(result2 == 42);
}
```

### UserData Integration

luaz has automatic compile-time binding generation for user data. It supports constructors, static and instance 
methods. If a struct has `deinit`, it'll be automatically invoked on garbage collection.

```zig
const std = @import("std");
const luaz = @import("luaz");
const assert = std.debug.assert;

const Counter = struct {
    value: i32,

    pub fn init(initial: i32) Counter {
        return Counter{ .value = initial };
    }

    pub fn deinit(self: *Counter) void {
        std.log.info("Counter with value {} being destroyed", .{self.value});
    }

    pub fn getMaxValue() i32 {
        return std.math.maxInt(i32);
    }

    pub fn increment(self: *Counter, amount: i32) i32 {
        self.value += amount;
        return self.value;
    }

    pub fn getValue(self: *const Counter) i32 {
        return self.value;
    }

    // Metamethods for arithmetic operations
    pub fn __add(self: Counter, other: i32) Counter {
        return Counter{ .value = self.value + other };
    }

    pub fn __tostring(self: Counter) []const u8 {
        return std.fmt.allocPrint(std.heap.page_allocator, "Counter({})", .{self.value}) catch "Counter";
    }

    pub fn __len(self: Counter) i32 {
        return self.value;
    }
};

pub fn main() !void {
    var lua = try luaz.Lua.init(null);
    defer lua.deinit();

    // Register Counter type with Lua
    try lua.registerUserData(Counter);

    _ = try lua.eval(
        \\local counter = Counter.new(10)     -- Use constructor
        \\assert(counter:increment(5) == 15)  -- Call instance method
        \\assert(counter:getValue() == 15)   -- Get current value
        \\
        \\local max = Counter.getMaxValue()   -- Call static method
        \\assert(max == 2147483647)           -- Max i32 value
        \\
        \\-- Metamethods in action
        \\local new_counter = counter + 5     -- Uses __add metamethod
        \\assert(new_counter:getValue() == 20)
        \\assert(#counter == 15)              -- Uses __len metamethod
        \\print(tostring(counter))            -- Uses __tostring metamethod
    , .{}, void);
}
```

> [!WARNING]
> This library is still evolving and the API is not stable. Backward incompatible changes may be introduced up until the 1.0 release. Consider pinning to a specific commit or tag if you need stability.

## 🗺️ Roadmap

The following features are planned after the initial release:

- Luau sandbox APIs - Safe execution environments for untrusted code
- Coroutine / threads support - Full Luau coroutine and threading capabilities
- Debug APIs - Debugging hooks and introspection tools
- GC API - Fine-grained garbage collection control
- Optional JSON support - Built-in JSON serialization/deserialization

## 🛠️ Using Luau Tools

The build system provides prebuilt Luau tools that can be invoked directly:

### Analyzer
```bash
$ zig build luau-analyze -- --help
Usage: /Users/.../luaz/.zig-cache/o/.../luau-analyze [--mode] [options] [file list]

Available modes:
  omitted: typecheck and lint input files
  --annotate: typecheck input files and output source with type annotations

Available options:
  --formatter=plain: report analysis errors in Luacheck-compatible format
  --formatter=gnu: report analysis errors in GNU-compatible format
  --mode=strict: default to strict mode when typechecking
  --timetrace: record compiler time tracing information into trace.json
```

### Compiler
```bash
$ zig build luau-compile -- --help
Usage: /Users/.../luaz/.zig-cache/o/.../luau-compile [--mode] [options] [file list]

Available modes:
   binary, text, remarks, codegen

Available options:
  -h, --help: Display this usage message.
  -O<n>: compile with optimization level n (default 1, n should be between 0 and 2).
  -g<n>: compile with debug level n (default 1, n should be between 0 and 2).
  --target=<target>: compile code for specific architecture (a64, x64, a64_nf, x64_ms).
  ...
```

## 🔗 Related Projects

These projects served as inspiration and are worth exploring:

- [zig-autolua](https://github.com/daurnimator/zig-autolua) - Automatic Lua bindings for Zig
- [zoltan](https://github.com/ranciere/zoltan) - Lua bindings for Zig
- [ziglua](https://github.com/natecraddock/ziglua) - Zig bindings for Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
