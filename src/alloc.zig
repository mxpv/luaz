//! Allocator wrapper for Lua VM integration.
//!
//! This module provides a C-compatible allocator function that wraps Zig's allocator
//! interface. The Zig allocator must be passed as a pointer to maintain compatibility
//! with Lua's C-based memory management system.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Lua allocator function that wraps a Zig allocator.
///
/// # Arguments
/// - `ptr` - a pointer to the block being allocated/reallocated/freed.
/// - `osize` - the original size of the block or some code about what is being allocated
/// - `nsize` - the new size of the block.
pub fn alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    // Lua assumes the following behavior from the allocator function:
    // - When nsize is zero, the allocator must behave like free and return NULL.
    // - When nsize is not zero, the allocator must behave like realloc.
    //   The allocator returns NULL if and only if it cannot fulfill the request.
    // Lua assumes that the allocator never fails when osize >= nsize.

    // realloc requests a new byte size for an existing allocation, which can be larger, smaller,
    // or the same size as the old memory allocation.
    // If `new_n` is 0, this is the same as free and it always succeeds.
    // `old_mem` may have length zero, which makes a new allocation.
    // See https://ziglang.org/documentation/0.14.1/std/#std.mem.Allocator.realloc
    const allocator: *const Allocator = @ptrCast(@alignCast(ud.?));

    // Handle all cases with realloc: allocation, reallocation, and freeing
    const old_slice = if (ptr) |old_ptr|
        @as([*]u8, @ptrCast(old_ptr))[0..osize]
    else
        @as([]u8, &.{});

    const new_slice = allocator.realloc(old_slice, nsize) catch return null;

    // When nsize is 0, realloc acts as free and returns an empty slice
    // Lua expects NULL in this case
    if (nsize == 0) {
        return null;
    }

    return @ptrCast(new_slice.ptr);
}
