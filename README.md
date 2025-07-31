<p align="center">
  <img src="docs/logo.png" />
</p>

# luaz

luaz is a zero-cost wrapper library for Luau. Unlike other libraries, it focuses specifically on Luau, providing
idiomatic Zig bindings that leverage Luau's unique features and performance characteristics.

The build system provides the `luau-compiler` out of the box, making it easy to compile and embed Luau scripts
directly into your Zig applications.

## ✨ Features

- Minimal yet flexible zero-cost API.
- Zig functions automatically callable from Lua.
- Native `Vector` type support.
- Supports Luau code generation for improved performance on supported platforms.
- Built-in Luau compiler (`luau-compile` tool) provided by the build system.
- Excellent test coverage and API documentation.

## 🔗 Related Projects

These projects served as inspiration and are worth exploring:

- [zig-autolua](https://github.com/daurnimator/zig-autolua) - Automatic Lua bindings for Zig
- [zoltan](https://github.com/ranciere/zoltan) - Lua bindings for Zig
- [ziglua](https://github.com/natecraddock/ziglua) - Zig bindings for Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

