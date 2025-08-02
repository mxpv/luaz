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

