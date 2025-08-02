<p align="center">
  <img src="docs/logo.png" />
</p>

# luaz

[![CI](https://github.com/mxpv/luaz/actions/workflows/ci.yml/badge.svg)](https://github.com/mxpv/luaz/actions/workflows/ci.yml)

`luaz` is a zero-cost wrapper library for [`Luau`](https://github.com/luau-lang/luau).
Unlike other libraries, it focuses specifically on Luau, providing idiomatic Zig bindings that leverage Luau's unique
features and performance characteristics.

The build system provides prebuilt Luau tools out of the box:
- `luau-compiler`: Compile Luau source to bytecode
- `luau-analyzer`: Typecheck and lint Luau code

These tools make it easy to compile, analyze, and embed Luau scripts directly into your Zig applications.

## ✨ Features

- Minimal yet flexible zero-cost API.
- Bidirectional function calls between Zig and Lua.
- First-class userdata support.
- Native support for refs, functions, tables, and vector types.
- Supports Luau code generation for improved performance on supported platforms.
- Built-in Luau tools (`luau-compile` and `luau-analyze`) provided by the build system.
- Excellent test coverage and API documentation.

## 📖 Usage Examples

### Basic Usage

The following example demonstrates some basic use cases.

Global table is available via `globals()`.

`eval` is a helper function that compiles Lua code to Luau bytecode and executes it.

Note: ideally, bundled  `luau-compile` tool should be used to precompile Lua scripts offline.

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

    pub fn create() Counter {
        return Counter.init(0);
    }

    pub fn increment(self: *Counter, amount: i32) i32 {
        self.value += amount;
        return self.value;
    }
};

pub fn main() !void {
    var lua = try luaz.Lua.init(null);
    defer lua.deinit();

    // Register Counter type with Lua
    try lua.registerUserData(Counter);

    _ = try lua.eval(
        \\local counter = Counter.create()  -- Call static method
        \\assert(counter:increment(5) == 5) -- Call instance method
        \\assert(counter:increment(3) == 8) -- Value persists
        \\
        \\local counter2 = Counter.init(10) -- Use constructor
        \\assert(counter2:increment(2) == 12)
    , .{}, void);
}
```

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

