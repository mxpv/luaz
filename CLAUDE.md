# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`luaz` is a zero-cost wrapper library for Luau written in Zig. It provides idiomatic Zig bindings for the Luau
scripting language, focusing specifically on Luau's unique features and performance characteristics.

The project consists of three main Zig modules:
- State (`src/State.zig`): Low-level Lua state wrapper providing direct access to Lua VM operations
- Compiler (`src/Compiler.zig`): Luau compiler interface for converting Lua source to bytecode
- Lua (`src/lua.zig`): High-level idiomatic Zig API with automatic type conversions

## Build System

The build system is written in Zig and provides several targets:

### Building
- `zig build` - Build the library
- `zig build test` - Run unit tests
- `zig build luau-compile` - Run the Luau compiler binary
- `zig build luau-analyze` - Run the Luau analyze binary
- `zig build docs` - Generate and install documentation
- `zig build check-fmt` - Check code formatting
- `zig build luau-vm` - Build Luau VM library only
- `zig build luau-codegen` - Build Luau codegen library only

### Key Libraries Built
- luau_vm: Core Luau virtual machine (from `luau/VM/src`)
- luau_codegen: JIT code generation (from `luau/CodeGen/src`) 
- luau_compiler: Luau compiler and AST (from `luau/Compiler/src` and `luau/Ast/src`)

The build system automatically discovers and compiles all `.cpp` and `.c` files in the respective Luau source
directories.

## Architecture

### High-Level API (`src/lua.zig`)
The main `Lua` struct provides an idiomatic Zig interface with automatic type conversions:
- `init()` - Initialize Lua state with optional custom allocator
- `enable_codegen()` - Enable Luau's JIT code generator for improved performance
- `globals()` - Access to the global environment table for setting/getting global variables
- `eval()` - Compile and execute Lua source code in one step
- `exec()` - Execute pre-compiled bytecode
- `createTable()` - Create new Lua tables with optional size hints
- `dumpStack()` - Debug utility to inspect the current Lua stack state
- `registerUserData()` - Register Zig structs as Lua userdata with automatic method binding
- `setAssertHandler()` - Set custom handler for Luau VM assertions

### Type System Integration
The library provides seamless conversion between Zig and Lua types through its high-level API:
- Zig functions are automatically wrapped as callable Lua functions with argument type checking
- Optional types (`?T`) map to Lua nil values
- Tuples are converted to Lua tables with array semantics
- Reference system (`Ref`) allows holding Lua values across function calls
- Table wrapper (`Table`) provides safe access to Lua tables with automatic type conversion
- Function wrapper (`Function`) provides direct access to Lua functions with automatic type conversion
- Generic Value type for runtime Lua value handling when types are unknown at compile time

### Table Operations
The library provides table operations through the `Table` type:
- Raw operations (`setRaw`/`getRaw`) bypass metamethods like `__index` and `__newindex` for direct table access
- Non-raw operations (`set`/`get`) invoke metamethods when present, providing full Lua semantics
- Function calling (`call`) retrieves and calls functions stored in tables with automatic argument and return type handling
- Function compilation (`compile`) compiles table functions to native code via JIT for better performance
- Table length (`len`) returns table length following Lua semantics, including metamethod support
- Table iteration (`next`) provides entry-by-entry iteration with automatic resource management
- Global access via `lua.globals()` returns a `Table` for interacting with the global environment
- Tables are reference-counted and must be explicitly released with `deinit()` (except globals table)

### UserData Support
The library provides automatic compile-time binding generation for Zig structs:
- `registerUserData(T)` creates Lua bindings for all public methods of struct type T
- Static methods and constructors are accessible as `TypeName.methodName()`
- Instance methods are accessible as `instance:methodName()`
- `init` methods are automatically renamed to `new` in Lua (e.g., `Counter.new()`)
- If struct has `deinit`, it's automatically called during Lua garbage collection
- Methods support automatic type conversion for arguments and return values

### Low-Level API (`src/State.zig`)
Direct wrapper around Luau C API providing:
- Complete stack manipulation operations
- Raw and non-raw table operations
- Garbage collection control
- Thread/coroutine management
- Standard library loading functions

### Compiler Integration (`src/Compiler.zig`)
Interfaces with the Luau compiler to:
- Compile Lua source to bytecode with configurable optimization levels
- Handle compilation errors with detailed error messages
- Support debug info and coverage options

### Custom Allocator Support
The library supports custom memory allocators through `Lua.init()`:
- Pass `null` to use Luau's default allocator
- Pass `&allocator` to use a custom Zig allocator
- The allocator pointer must remain valid for the Lua state's lifetime
- Deviates from typical Zig conventions due to C interop requirements
- All Lua memory operations (allocation, reallocation, freeing) go through the custom allocator

### Closure Upvalues (`setClosure`)
The `setClosure` method creates Lua C closures using the `Upvalues(T)` wrapper type:
- Functions must use `Upvalues(T)` as their first parameter
- Single upvalue: `setClosure("func", value, fn)` where fn takes `Upvalues(T)`
- Multiple upvalues: Use tuple `setClosure("func", .{val1, val2}, fn)` where fn takes `Upvalues(struct{T1, T2})`

Examples:
```zig
// Single upvalue
fn getValue(upv: Upvalues(*State), key: []const u8) i32 {
    return upv.value.getGlobal(key);
}
try table.setClosure("getValue", &state, getValue);

fn addFive(upv: Upvalues(i32), x: i32) i32 {
    return x + upv.value;
}
try table.setClosure("addFive", 5, addFive);

// Multiple upvalues - use tuple
fn transform(upv: Upvalues(struct { f32, f32 }), x: f32) f32 {
    return x * upv.value[0] + upv.value[1];
}
try table.setClosure("transform", .{ 2.0, 10.0 }, transform);
```

## Luau Submodule

This repository includes the full Luau source code as a Git submodule located at `/Users/mpavlenko/Github/luaz/luau`. When investigating Luau implementation details, behavior, or test patterns, use this submodule instead of searching external repositories. The submodule contains:

- VM source code in `luau/VM/src/`
- Test files in `luau/tests/` (C++ unit tests) and `luau/tests/conformance/` (Luau test scripts)
- Debug API implementation files like `ldebug.cpp`, `ldo.cpp`, and the main header `lua.h`
- Conformance tests that demonstrate proper usage patterns for debug functionality

Key test files for understanding debug features:
- `luau/tests/Conformance.test.cpp` - Contains C++ test code showing how to use `lua_break`, `debuginterrupt`, and breakpoint functionality
- `luau/tests/conformance/interrupt.luau` - Luau script for testing interrupt functionality
- `luau/tests/conformance/debugger.luau` - Luau script demonstrating breakpoint usage

## Development Patterns

### Versioning and Compatibility
The library is currently in pre-1.0 development. Breaking changes are acceptable and encouraged to improve the API design. Backward compatibility is not a concern until version 1.0 is released.

### Code Style
Write idiomatic Zig code following the established patterns in the codebase:
- Use explicit error handling with error unions and optionals
- Leverage Zig's comptime features for type safety and zero-cost abstractions
- Follow Zig naming conventions (camelCase for functions, PascalCase for types)
- Prefer explicit memory management over implicit allocation
- Do not write implementation comments that explain why code was written a certain way or reference previous implementations
- Don't solve problems by removing code - fix issues through proper implementation rather than deletion
- Always run `zig fmt .` after making code changes to ensure consistent formatting

### Testing
Unit tests should be written against public APIs in `tests.zig`. New functionality must include
corresponding unit tests. Tests use `&std.testing.allocator` for memory leak detection.

Keep unit tests minimal and focused. Tests must demonstrate that functionality works.
Write clear, concise tests that verify the feature without unnecessary complexity.
Keep unit tests short and understandable.

Important testing guidelines:
- `tests.zig` should include unit tests that test only public APIs
- Avoid using functions from `stack.zig` and `State.zig` in `tests.zig`
- Never use `stack.*` functions when testing public APIs - use only the high-level API methods
- Focus on testing the high-level API provided by `lua.zig`
- Don't create excessive and too verbose unit tests
- Each test must be minimal and aim to test a specific function
- Keep tests short, focused, and easy to understand
- Write meaningful tests that actually test the APIs and their intended behavior
- Tests must verify that specific API methods work correctly, not just that code runs without crashing
- Use specific assertions that validate expected outcomes rather than always-true conditions
- Each test should exercise actual API functionality and verify the correct behavior of the methods being tested

### Documentation
Keep documentation for public interfaces current but reasonably sized. The codebase uses Zig's built-in doc comments
(`///` syntax) extensively. When adding or modifying public functions, ensure documentation includes:
- Clear description of functionality and purpose
- Parameter descriptions and types
- Return value explanations
- Usage examples where helpful
- Error conditions and handling

Keep documentation concise and focused. Don't write extensive documentation - aim for reasonable size that covers the essentials without being verbose.

Documentation Formatting:
- Avoid empty lines in doc comments (lines with only `///`) as they will be skipped during documentation generation.
- NEVER use bold formatting (** **) anywhere in the repository - not in comments, not in markdown files, nowhere
- This includes **Important**, **Note**, **Warning**, or any other bold text

### Memory Management
- Lua states must be explicitly deinitialized with `deinit()`
- Compilation results must be freed with `Result.deinit()`
- References must be released with `Ref.deinit()`
- Tables must be released with `Table.deinit()`
- Functions must be released with `Function.deinit()`
- Generic Values must be released with `Value.deinit()` when containing reference types
- Table iteration entries must be released with `Entry.deinit()` or passed to next `next()` call
- The library uses Luau's garbage collector for Lua values
- Custom allocators (if provided to `init()`) must outlive the Lua state
- Use `&std.testing.allocator` in tests for memory leak detection

### Error Handling
The library defines custom error types:
- `Error.OutOfMemory` - VM memory allocation failures
- `Error.Compile` - Lua source compilation errors

Functions return error unions or optionals for type-safe error handling.

### Git Workflow
Keep commit messages brief and to the point:
- Use a short, descriptive commit title (50 characters or less)
- Include a brief commit body that summarizes changes in 1-3 sentences when needed (wrap at 120 characters)
- Do not include automated signatures or generation notices in commit messages or pull requests
- Don't add "Generated with Claude Code" to commit messages or pull request descriptions
- Don't add "Co-Authored-By: Claude noreply@anthropic.com" to commit messages or pull request descriptions
- Keep commits focused and atomic - one logical change per commit
- Ensure unit tests pass
- Before committing: verify all documentation examples match the current API signatures and behavior
- IMPORTANT: Always verify that the guided tour in README.md compiles and works correctly before pushing any commit or creating a pull request
- Before committing or creating a PR: always make sure the changelog is up to date
- Update changelog whenever there is a new API, breaking change, performance improvement, or anything else that changes behavior
- Prefer one-liner changelog updates describing changes from user perspective without implementation details

### Pull Request Guidelines
Keep PR descriptions concise and focused:
- Include the brief commit body summary plus relevant examples if applicable
- Avoid verbose sections like "Changes Made", "Test Plan", or extensive bullet lists
- Focus on what the change does and why, not exhaustive implementation details
- Include code examples only when they help demonstrate usage or key functionality
- Before creating PR: ensure all documentation examples are tested and work with the current API
- IMPORTANT: Always verify that the guided tour in README.md compiles and is up to date before creating a pull request
