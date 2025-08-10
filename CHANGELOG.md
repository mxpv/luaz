# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- **Luau StrBuf support** for efficient string building with automatic memory management
  - High-level `StrBuf` API with `init()`, `initSize()`, `addString()`, `addChar()`, and `add()` methods
  - Support for returning StrBuf from Zig functions with automatic pointer fixup
  - Integration with table operations and closure system
  - Handles both stack buffer (small strings) and dynamic allocation (large strings)
- Variadic arguments support with `Varargs` iterator for functions accepting variable number of arguments
  - `Varargs.raiseError()` method for throwing descriptive type validation errors
- **BREAKING**: `setClosure` Lua closures must use `Upvalues(T)` as first parameter
- Canonical Zig iterator pattern for table iteration with `Table.iterator()`
- Metatable management APIs:
  - `Lua.createMetaTable()` for flexible metatable creation without global registration
  - `Table.setMetaTable()` and `Table.getMetaTable()` for metatable attachment and retrieval
- `Table.clear()` method to remove all entries from a table
- `Table.clone()` method to create a shallow copy of a table
- `Function.clone()` method to create a copy of a function with shared upvalue references

### Changed
- **BREAKING**: Table iteration API now uses standard Zig iterator pattern (`iterator.next()`)
- Refactored `registerUserData` implementation to use new metatable APIs internally
- Renamed module files to follow Zig naming conventions:
  - `src/state.zig` → `src/State.zig`
  - `src/compile.zig` → `src/Compiler.zig`
  - Updated all imports to use the module directly instead of accessing nested types

### Removed
- **BREAKING**: Old manual table iteration method `Table.next()` in favor of canonical iterator

## [0.2.0] - 2025-08-06

### Added
- Sandboxing APIs for secure script execution
- Thread and coroutines support with full Luau threading capabilities
- Generic Lua Value type for runtime value handling
- Table iterator with automatic resource management
- Raw table operations for direct table access bypassing metamethods
- Low-level debug APIs for advanced debugging scenarios
- Metamethod support:
  - `__index` and `__newindex` for table access customization
  - `__tostring` for custom string conversion
  - `__len` for custom length operations
  - `__concat` for concatenation operations
  - Math operation metamethods (`__add`, `__sub`, `__mul`, `__div`, etc.)
  - Comparison metamethods (`__eq`, `__lt`, `__le`)
- Table length operations with `Table.len()` supporting full Lua semantics
- Support for error returns in Lua functions
- Struct and array return type conversion

### Changed
- Simplified resume API for streamlined coroutine management
- UserData improvements:
  - Support for `*Lua` receiver as first function parameter
  - UserData treated as `Ref` for consistent reference handling
  - No longer requires at least 1 public function when registering
- Arbitrary structs can be set as Lua tables
- Use `pcall` instead of direct `call` for improved error safety
- Exposed GC API for greater control over garbage collection

### Documentation
- Updated guided tour with new features
- Enhanced README with additional examples
- Added test coverage reporting

## [0.1.0] - Initial Release

### Added
- Core Lua state management with `State` wrapper
- High-level idiomatic Zig API through `Lua` struct
- Luau compiler integration for source-to-bytecode compilation
- Type system integration with automatic conversions:
  - Zig functions wrapped as callable Lua functions
  - Optional types (`?T`) mapping to Lua nil values
  - Tuples converted to Lua tables with array semantics
  - Support for vectors and primitive types
- Table operations:
  - Create, set, and get table values
  - Call table functions with automatic type handling
  - Global environment access via `lua.globals()`
- Reference system (`Ref`) for holding Lua values across function calls
- Function references for direct Lua function access
- UserData support:
  - Register Zig structs as Lua userdata
  - Automatic method binding with compile-time generation
  - Light userdata support
- Custom allocator support through `Lua.init()`
- JIT code generation with `enable_codegen()`
- Standard library loading functions
- Debug utilities:
  - Stack dumping with `dumpStack()`
  - Custom assert handler support
- Build system:
  - Automatic discovery and compilation of Luau source files
  - Multiple build targets (library, compiler, analyzer, docs)
  - Code formatting checks
- Documentation generation
- Unit test suite with memory leak detection
- Continuous integration with coverage reporting