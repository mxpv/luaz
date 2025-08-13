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
- `deinit()` - Clean up Lua state and free resources
- `openLibs()` - Open all standard Lua libraries (math, string, table, etc.)
- `enable_codegen()` - Enable Luau's JIT code generator for improved performance
- `globals()` - Access to the global environment table for setting/getting global variables
- `eval()` - Compile and execute Lua source code in one step
- `exec()` - Execute pre-compiled bytecode
- `createTable()` - Create new Lua tables with optional size hints
- `createMetaTable()` - Create metatable for a specific type with automatic method registration
- `createThread()` - Create new Lua thread/coroutine for concurrent execution
- `dumpStack()` - Debug utility to inspect the current Lua stack state
- `registerUserData()` - Register Zig structs as Lua userdata with automatic method binding
- `setAssertHandler()` - Set custom handler for Luau VM assertions
- `setCallbacks()` - Set VM callbacks for events like function calls and returns
- `sandbox()` - Enable sandbox mode for restricted execution environment
- `debug()` - Access debug functionality for breakpoints and tracing
- `gc()` - Access garbage collector control for memory management
- `top()` - Get current stack top position
- `status()` - Get coroutine/thread execution status
- `isYieldable()` - Check if current state can yield
- `reset()` / `isReset()` - Reset state to initial condition
- `getData()` / `setData()` - Manage user-defined data pointer
- `isThread()` - Check if this state is a thread/coroutine

### Type System Integration
The library provides seamless conversion between Zig and Lua types through its high-level API:
- Zig functions are automatically wrapped as callable Lua functions with argument type checking
- Optional types (`?T`) map to Lua nil values
- Tuples are converted to Lua tables with array semantics
- Reference system (`Ref`) allows holding Lua values across function calls
- Table wrapper (`Table`) provides safe access to Lua tables with automatic type conversion
- Function wrapper (`Function`) provides direct access to Lua functions with automatic type conversion
- Generic Value type for runtime Lua value handling when types are unknown at compile time
- Varargs iterator for handling variadic function arguments
- StrBuf for efficient string building and concatenation
- Result wrapper for function return values with multiple results support

### Table Operations
The library provides table operations through the `Table` type:
- Raw operations (`setRaw`/`getRaw`) bypass metamethods like `__index` and `__newindex` for direct table access
- Non-raw operations (`set`/`get`) invoke metamethods when present, providing full Lua semantics
- Closure setting (`setClosure`) sets functions with upvalues for persistent state
- Function calling (`call`) retrieves and calls functions stored in tables with automatic argument and return type handling
- Function compilation (`compile`) compiles table functions to native code via JIT for better performance
- Table length (`len`) returns table length following Lua semantics, including metamethod support
- Table iteration (`iterator`) creates an iterator for traversing table entries
- Readonly control (`setReadonly`/`isReadonly`) manages table mutability
- Safe environment (`setSafeEnv`) marks table as safe execution environment
- Metatable management (`setMetaTable`/`getMetaTable`) controls table behavior
- Table utilities (`clear`/`clone`) for resetting and duplicating tables
- Global access via `lua.globals()` returns a `Table` for interacting with the global environment
- Tables are reference-counted and must be explicitly released with `deinit()` (except globals table)

### Function Operations
The library provides function operations through the `Function` type:
- Function calling (`call`) invokes the function with automatic type conversion
- JIT compilation (`compile`) compiles the function to native code for better performance
- Function cloning (`clone`) creates a duplicate of the function
- Breakpoint support (`setBreakpoint`) for debugging with line-level control
- Functions are reference-counted and must be explicitly released with `deinit()`

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

The repository includes the full Luau source code as a Git submodule at `luau/`. 
For investigating implementation details, see the `general-purpose` agent configuration.

## Using Subagents

When working with Claude Code on this repository, use specialized subagents for complex or multi-step tasks. These agents can work in sequence to handle complete workflows.

### When to Use Subagents
- Use the `general-purpose` agent for:
  - Searching for specific patterns or implementations across the codebase
  - Investigating Luau submodule implementation details
  - Complex debugging tasks requiring multiple file searches
  - Understanding how specific features are implemented in the C++ code

- Use the `committer` agent for:
  - Creating git commits with properly formatted messages
  - Ensuring commits follow the repository's strict guidelines (no AI attribution)
  - Staging and committing changes atomically

- Use the `note-keeper` agent for:
  - Updating the CHANGELOG.md with new features or changes
  - Maintaining consistent changelog format
  - Documenting user-facing changes

- Use the `guide` agent for:
  - Automatically triggered when CHANGELOG.md is modified in a commit
  - Ensuring documentation consistency after changes
  - Verifying examples and guides are up to date

- Use the `luau-updater` agent for:
  - Updating the Luau submodule to the latest version
  - Handling submodule synchronization and dependency updates
  - Ensuring compatibility after Luau updates

- Use the `releaser` agent for:
  - Creating new releases with proper versioning
  - Generating release notes from changelog
  - Tagging releases appropriately

### Sequential Agent Workflows
These agents often work together in sequence:
1. Make code changes → `committer` creates the commit
2. If CHANGELOG.md is updated → `guide` automatically verifies documentation
3. When ready for release → `releaser` handles the release process

### Subagent Usage Examples
- "Search for all uses of lua_break in the codebase" - Use general-purpose agent
- "Find how metamethods are implemented" - Use general-purpose agent  
- "Commit these changes" - Use committer agent (handles all commit guidelines automatically)
- "Update the changelog" - Use note-keeper agent (maintains format consistency)
- "Update luau" - Use luau-updater agent (handles submodule updates)
- "Make a new release" - Use releaser agent (manages versioning and tagging)
- "Create a PR for this feature" - Use committer agent (enforces PR guidelines)

## Development Patterns

### Versioning and Compatibility
The library is currently in pre-1.0 development. Breaking changes are acceptable and encouraged to improve the API design. Backward compatibility is not a concern until version 1.0 is released.

### Code Style
See the `general-purpose` agent configuration for detailed code style guidelines and development patterns.

### Testing
Unit tests should be written against public APIs in `tests.zig`. New functionality must include corresponding unit tests.
See the `general-purpose` agent configuration for detailed testing guidelines and patterns.

### Documentation
Keep documentation for public interfaces current but reasonably sized. The codebase uses Zig's built-in doc comments (`///` syntax).
See the `general-purpose` agent configuration for documentation formatting guidelines.

### Memory Management
The library requires explicit memory management for Lua values and states.
See the `general-purpose` agent configuration for detailed memory management rules.

### Error Handling
The library defines custom error types:
- `Error.OutOfMemory` - VM memory allocation failures
- `Error.Compile` - Lua source compilation errors

Functions return error unions or optionals for type-safe error handling.

### Git Workflow
- For commits: Use the `committer` agent which handles proper formatting and enforces repository guidelines
- For changelog updates: Use the `note-keeper` agent to maintain consistent format
- For releases: Use the `releaser` agent for proper versioning and tagging
- Ensure unit tests pass before committing
- Verify documentation examples match current API signatures
