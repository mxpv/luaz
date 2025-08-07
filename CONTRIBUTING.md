# Contributing to luaz

Pull requests are welcome! We appreciate your contributions to making `luaz` better.

## Submission Guidelines

- Description:
  - Add a brief description that articulates the motivation and explains what the change does and why it is needed
- Code Quality:
  - Make sure the change is cleanly written and follows existing code patterns
  - Always run `zig fmt .` before committing to ensure consistent formatting
  - Follow the idiomatic Zig patterns established in the codebase
- Testing: All changes must be covered by unit tests
  - Run tests with `zig build test`
  - Ensure your code is actually executed in tests (Zig skips unused code during compilation)
- Documentation: Update relevant documentation using Zig's doc comment syntax (`///`) if your change affects public APIs
- Issue References: If your PR fixes an existing issue, mention it in the PR description (e.g., "Fixes #123")

## Quick Start

1. Fork the repository
2. Create a feature branch for your changes
3. Make your changes following the guidelines above
4. Run `zig fmt .` to format your code
5. Ensure all tests pass with `zig build test`
6. Submit a pull request with a clear description

Thank you for contributing to luaz!
