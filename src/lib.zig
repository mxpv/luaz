//! **luaz** - Zero-cost wrapper library for Luau written in Zig
//!
//! This library provides idiomatic Zig bindings for the Luau scripting language,
//! focusing on Luau's unique features and performance characteristics.

// Core types
pub const Lua = @import("Lua.zig");
pub const State = @import("State.zig");
pub const Compiler = @import("Compiler.zig");
pub const Debug = @import("Debug.zig");
pub const GC = @import("GC.zig");

// Assert handling
pub const setAssertHandler = @import("assert.zig").setAssertHandler;
pub const AssertHandler = @import("assert.zig").AssertHandler;
