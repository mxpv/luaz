# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`luaz` is a zero-cost wrapper library for Luau written in Zig. It provides idiomatic Zig bindings for the Luau
scripting language, focusing specifically on Luau's unique features and performance characteristics.

The project consists of three main Zig modules:
- **State** (`src/state.zig`): Low-level Lua state wrapper providing direct access to Lua VM operations
- **Compiler** (`src/compile.zig`): Luau compiler interface for converting Lua source to bytecode
- **Lua** (`src/root.zig`): High-level idiomatic Zig API with automatic type conversions

## Build System

The build system is written in Zig and provides several targets:

### Building
- `zig build` - Build the library
- `zig build test` - Run unit tests
- `zig build luau-compile` - Run the Luau compiler binary

### Key Libraries Built
- **luau_vm**: Core Luau virtual machine (from `luau/VM/src`)
- **luau_codegen**: JIT code generation (from `luau/CodeGen/src`) 
- **luau_compiler**: Luau compiler and AST (from `luau/Compiler/src` and `luau/Ast/src`)

The build system automatically discovers and compiles all `.cpp` and `.c` files in the respective Luau source
directories.

## Architecture

### High-Level API (`src/root.zig`)
The main `Lua` struct provides an idiomatic Zig interface with automatic type conversions:
- `push()` - Converts Zig values to Lua (integers, floats, bools, optionals, tuples, functions, tables)
- `pop()` - Converts Lua values back to Zig types
- `setGlobal()`/`getGlobal()` - Global variable access
- `eval()` - Compile and execute Lua source code in one step
- `exec()` - Execute pre-compiled bytecode
- `createTable()` - Create new Lua tables with optional size hints

### Type System Integration
The library provides seamless conversion between Zig and Lua types:
- Zig functions are automatically wrapped as callable Lua functions with argument type checking
- Optional types (`?T`) map to Lua nil values
- Tuples are pushed as multiple stack values
- Reference system (`Ref`) allows holding Lua values across function calls
- Table wrapper (`Table`) provides safe access to Lua tables with automatic type conversion

### Table Operations
The library provides both raw and non-raw table operations:
- **Raw operations** (`setRaw`/`getRaw`) bypass metamethods like `__index` and `__newindex` for direct table access
- **Non-raw operations** (`set`/`get`) invoke metamethods when present, providing full Lua semantics
- Tables are reference-counted and must be explicitly released with `deinit()`

### Low-Level API (`src/state.zig`)
Direct wrapper around Luau C API providing:
- Complete stack manipulation operations
- Raw and non-raw table operations
- Garbage collection control
- Thread/coroutine management
- Standard library loading functions

### Compiler Integration (`src/compile.zig`)
Interfaces with the Luau compiler to:
- Compile Lua source to bytecode with configurable optimization levels
- Handle compilation errors with detailed error messages
- Support debug info and coverage options

## Development Patterns

### Code Style
Write idiomatic Zig code following the established patterns in the codebase:
- Use explicit error handling with error unions and optionals
- Leverage Zig's comptime features for type safety and zero-cost abstractions
- Follow Zig naming conventions (camelCase for functions, PascalCase for types)
- Prefer explicit memory management over implicit allocation

### Testing
All modules include unit tests demonstrating usage patterns. New functionality must include
corresponding unit tests. Tests cover:
- Type conversion edge cases
- Function wrapping and calling
- Global variable manipulation
- Table operations (raw and non-raw)
- Compilation error handling
- Reference and table management

Write unit tests with good coverage, but no need to be comprehensive and try to cover every possible case.
Keep unit tests reasonably short.

### Documentation
Keep documentation for public interfaces current and comprehensive. The codebase uses Zig's built-in doc comments
(/// syntax) extensively. When adding or modifying public functions, ensure documentation includes:
- Clear description of functionality and purpose
- Parameter descriptions and types
- Return value explanations
- Usage examples where helpful
- Error conditions and handling

### Memory Management
- Lua states must be explicitly deinitialized with `deinit()`
- Compilation results must be freed with `Result.deinit()`
- References must be released with `Ref.deinit()`
- Tables must be released with `Table.deinit()`
- The library uses Luau's garbage collector for Lua values

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

### Pull Request Guidelines
Keep PR descriptions concise and focused:
- Include the brief commit body summary plus relevant examples if applicable
- Avoid verbose sections like "Changes Made", "Test Plan", or extensive bullet lists
- Focus on what the change does and why, not exhaustive implementation details
- Include code examples only when they help demonstrate usage or key functionality