const c = @cImport({
    @cInclude("handler.h");
});

/// Assert handler function type for Luau VM assertions.
pub const AssertHandler = c.Luau_AssertHandler;

/// Set a custom assert handler for Luau VM assertions.
///
/// The handler is called when a Luau VM assertion fails, allowing custom error
/// handling and debugging. The handler receives information about the failed assertion
/// including expression, file, line number, and function name.
///
/// Parameters:
/// - handler: Function pointer with signature (expr, file, line, func) -> c_int
///   Returns 0 to abort, non-zero to continue execution
pub inline fn setAssertHandler(handler: AssertHandler) void {
    c.luau_set_assert_handler(handler);
}
