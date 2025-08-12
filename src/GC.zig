//! Garbage collection control for Luau.
//!
//! This module provides fine-grained control over Luau's incremental garbage collector.
//! Luau uses an incremental garbage collector that performs work in small increments
//! without stopping the world. These methods allow you to monitor memory usage,
//! tune GC performance, or manually control collection timing.
//!
//! ## Basic Usage
//!
//! ```zig
//! const lua = try Lua.init(null);
//! defer lua.deinit();
//!
//! const gc = lua.gc();
//!
//! // Check current memory usage
//! const memory_kb = gc.count();
//! std.debug.print("Memory usage: {} KB\n", .{memory_kb});
//!
//! // Force garbage collection
//! gc.collect();
//!
//! // Check memory after collection
//! const memory_after = gc.count();
//! std.debug.print("Memory after GC: {} KB\n", .{memory_after});
//! ```
//!
//! ## Manual GC Control
//!
//! ```zig
//! const gc = lua.gc();
//! gc.stop();  // Disable automatic GC
//!
//! // Do memory-intensive work
//! // ...
//!
//! // Manually step through GC
//! while (!gc.step(100)) {
//!     // GC cycle not complete, continue with work
//! }
//!
//! gc.restart();  // Re-enable automatic GC
//! ```
//!
//! ## Performance Tuning
//!
//! ```zig
//! const gc = lua.gc();
//!
//! // Make GC more aggressive (less memory, more CPU)
//! gc.setGoal(150);     // Start GC when memory increases by 50%
//! gc.setStepMul(300);  // Do more work per step
//!
//! // Make GC less aggressive (more memory, less CPU)
//! gc.setGoal(250);     // Start GC when memory increases by 150%
//! gc.setStepMul(150);  // Do less work per step
//! ```

const std = @import("std");
const State = @import("State.zig");

// Forward declare Lua to avoid circular import
const Lua = @import("Lua.zig");

lua: Lua,

const Self = @This();

/// Stop the garbage collector.
///
/// Disables automatic garbage collection. Memory will continue to be allocated
/// but no garbage collection cycles will run until `restart()` is called.
/// Use with caution as this can lead to excessive memory usage.
///
/// Example:
/// ```zig
/// const gc = lua.gc();
/// gc.stop();  // GC is now disabled
/// // ... do memory-intensive work
/// gc.restart();  // Re-enable GC
/// ```
pub fn stop(self: Self) void {
    _ = self.lua.state.gc(.stop, 0);
}

/// Restart the garbage collector.
///
/// Re-enables automatic garbage collection after it was stopped with `stop()`.
/// The garbage collector will resume its normal incremental collection cycles.
///
/// Example:
/// ```zig
/// const gc = lua.gc();
/// gc.stop();
/// // ... do work with GC disabled
/// gc.restart();  // GC is active again
/// ```
pub fn restart(self: Self) void {
    _ = self.lua.state.gc(.restart, 0);
}

/// Force a full garbage collection cycle.
///
/// Performs a complete garbage collection pass, freeing all unreachable objects.
/// This is more thorough than the incremental collection and may cause a brief pause.
/// Useful for reclaiming memory at application boundaries or after large operations.
///
/// Example:
/// ```zig
/// const gc = lua.gc();
/// // After loading large amounts of data
/// gc.collect();  // Free any unused memory
/// ```
pub fn collect(self: Self) void {
    _ = self.lua.state.gc(.collect, 0);
}

/// Get the total memory usage in kilobytes.
///
/// Returns the total amount of memory currently used by the Lua state,
/// including all Lua objects, strings, tables, functions, etc.
/// The value is returned in kilobytes (1024 bytes).
///
/// Example:
/// ```zig
/// const gc = lua.gc();
/// const memory_kb = gc.count();
/// std.debug.print("Lua memory usage: {} KB\n", .{memory_kb});
/// ```
///
/// Returns: Memory usage in kilobytes
pub fn count(self: Self) i32 {
    return self.lua.state.gc(.count, 0);
}

/// Get the fractional part of memory usage.
///
/// Returns the remainder of memory usage in bytes after the kilobyte count.
/// Combined with `count()`, this gives precise memory usage:
/// `total_bytes = count() * 1024 + countBytes()`
///
/// Example:
/// ```zig
/// const gc = lua.gc();
/// const kb = gc.count();
/// const bytes = gc.countBytes();
/// const total_bytes = kb * 1024 + bytes;
/// std.debug.print("Precise memory usage: {} bytes\n", .{total_bytes});
/// ```
///
/// Returns: Additional bytes beyond the kilobyte count (0-1023)
pub fn countBytes(self: Self) i32 {
    return self.lua.state.gc(.countb, 0);
}

/// Check if the garbage collector is currently running.
///
/// Returns `true` if automatic garbage collection is enabled and active,
/// `false` if it has been stopped with `stop()` or is otherwise disabled.
///
/// Example:
/// ```zig
/// const gc = lua.gc();
/// if (gc.isRunning()) {
///     std.debug.print("GC is active\n");
/// } else {
///     std.debug.print("GC is stopped\n");
/// }
/// ```
///
/// Returns: `true` if GC is running, `false` otherwise
pub fn isRunning(self: Self) bool {
    return self.lua.state.gc(.isrunning, 0) != 0;
}

/// Perform a single incremental garbage collection step.
///
/// Runs one step of the incremental garbage collector. The `size` parameter
/// controls how much work to do in this step (larger values = more work).
/// Returns `true` if the GC cycle completed, `false` if more steps are needed.
///
/// This is useful for manual control over GC timing in performance-critical code.
///
/// Example:
/// ```zig
/// const gc = lua.gc();
/// gc.stop();  // Disable automatic GC
///
/// while (!gc.step(100)) {
///     // GC cycle not complete, do some work
///     // ... application work ...
/// }
/// // GC cycle completed
/// ```
///
/// Parameters:
/// - `size`: Amount of work to perform (typically 100-1000)
///
/// Returns: `true` if GC cycle completed, `false` if more work remains
pub fn step(self: Self, size: i32) bool {
    return self.lua.state.gc(.step, size) != 0;
}

/// Set the garbage collection goal.
///
/// Controls when the next GC cycle should start based on memory usage.
/// The goal is specified as a percentage of current memory usage.
/// For example, a goal of 200 means GC will start when memory usage
/// doubles from the current level.
///
/// Lower values trigger GC more frequently (less memory usage, more CPU overhead).
/// Higher values trigger GC less frequently (more memory usage, less CPU overhead).
///
/// Example:
/// ```zig
/// const gc = lua.gc();
/// gc.setGoal(150);  // Start GC when memory increases by 50%
/// ```
///
/// Parameters:
/// - `goal`: GC trigger threshold as percentage (typically 100-300)
///
/// Returns: Previous goal value
pub fn setGoal(self: Self, goal: i32) i32 {
    return self.lua.state.gc(.setgoal, goal);
}

/// Set the garbage collection step multiplier.
///
/// Controls how much work the GC does in each incremental step relative
/// to memory allocation. Higher values make GC more aggressive (more CPU
/// overhead but lower memory usage), lower values make it less aggressive.
///
/// The default value is typically around 200. Values between 100-500 are common.
///
/// Example:
/// ```zig
/// const gc = lua.gc();
/// gc.setStepMul(300);  // Make GC more aggressive
/// ```
///
/// Parameters:
/// - `stepmul`: Step multiplier (typically 100-500)
///
/// Returns: Previous step multiplier value
pub fn setStepMul(self: Self, stepmul: i32) i32 {
    return self.lua.state.gc(.setstepmul, stepmul);
}

/// Set the garbage collection step size.
///
/// Controls the size of each incremental GC step in bytes. Larger step sizes
/// mean fewer but larger GC pauses, smaller step sizes mean more frequent
/// but shorter pauses.
///
/// This fine-tunes the incremental GC behavior for specific performance needs.
///
/// Example:
/// ```zig
/// const gc = lua.gc();
/// gc.setStepSize(1024);  // 1KB per GC step
/// ```
///
/// Parameters:
/// - `stepsize`: Size of each GC step in bytes
///
/// Returns: Previous step size value
pub fn setStepSize(self: Self, stepsize: i32) i32 {
    return self.lua.state.gc(.setstepsize, stepsize);
}

// Tests for GC functionality
const expect = std.testing.expect;

test "garbage collector operations" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    lua.openLibs();

    const gc = lua.gc();

    // Test that GC is initially running
    try expect(gc.isRunning());

    // Test memory counting
    const initial_memory = gc.count();
    const initial_bytes = gc.countBytes();
    try expect(initial_memory >= 0);
    try expect(initial_bytes >= 0 and initial_bytes < 1024);

    // Create some objects to increase memory usage
    const globals = lua.globals();
    try globals.set("test_table", lua.createTable(.{ .rec = 100 }));

    _ = try lua.eval(
        \\for i = 1, 100 do
        \\  test_table[i] = "string number " .. i
        \\end
    , .{}, void);

    // Memory should have increased
    const after_alloc_memory = gc.count();
    try expect(after_alloc_memory >= initial_memory);

    // Test stopping and restarting GC
    gc.stop();
    try expect(!gc.isRunning());

    gc.restart();
    try expect(gc.isRunning());

    // Test forcing garbage collection
    gc.collect();
    const after_collect_memory = gc.count();

    // Memory might be same or less after collection
    // (depends on what was actually collectible)
    try expect(after_collect_memory >= 0);

    // Test GC stepping
    gc.stop();
    try expect(!gc.isRunning());

    // Create more garbage
    _ = try lua.eval(
        \\local temp = {}
        \\for i = 1, 50 do
        \\  temp[i] = {}
        \\  for j = 1, 10 do
        \\    temp[i][j] = "temp string " .. i .. "," .. j
        \\  end
        \\end
        \\temp = nil
    , .{}, void);

    // Perform stepped collection
    var steps: u32 = 0;
    while (!gc.step(100) and steps < 10) {
        steps += 1;
    }

    // Should have completed within reasonable steps
    try expect(steps < 10);

    // Test GC parameter setting
    const old_goal = gc.setGoal(150);
    try expect(old_goal > 0);

    const old_stepmul = gc.setStepMul(250);
    try expect(old_stepmul > 0);

    const old_stepsize = gc.setStepSize(2048);
    try expect(old_stepsize > 0);

    // Restore original parameters
    _ = gc.setGoal(old_goal);
    _ = gc.setStepMul(old_stepmul);
    _ = gc.setStepSize(old_stepsize);

    gc.restart();
    try expect(gc.isRunning());
}

test "gc memory measurement precision" {
    const lua = try Lua.init(&std.testing.allocator);
    defer lua.deinit();

    const gc = lua.gc();

    // Test precise memory measurement
    const kb = gc.count();
    const bytes = gc.countBytes();
    const total_bytes = kb * 1024 + bytes;

    try expect(kb >= 0);
    try expect(bytes >= 0 and bytes < 1024);
    try expect(total_bytes >= 0);

    // Allocate a known amount and verify memory increases
    const globals = lua.globals();
    const large_table = lua.createTable(.{ .arr = 1000 });
    defer large_table.deinit();

    try globals.set("large_table", large_table);

    // Fill table with data
    _ = try lua.eval(
        \\for i = 1, 1000 do
        \\  large_table[i] = i
        \\end
    , .{}, void);

    const kb_after = gc.count();
    const bytes_after = gc.countBytes();
    const total_bytes_after = kb_after * 1024 + bytes_after;

    // Memory should have increased significantly
    try expect(total_bytes_after > total_bytes);
}
