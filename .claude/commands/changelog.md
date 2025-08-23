---
description: Update CHANGELOG.md with new changes
---

Keep CHANGELOG.md up to date.

Arguments: `$ARGUMENTS` (optional additional context or specific changes to highlight)

## Guidelines

- Whenever there is a new API, or a change to a public facing API, deprecation, or any backward incompatible changes, those must be reflected in the changelog file
- Keep changelog minimal and clean, preferably oneliners
- For big and complex features it's ok to add sub-list with bullets
- Write changes from end-user perspective
- Don't update changelog lines for maintenance tasks, such as readme updates, CLAUDE configuration changes, cosmetic changes, documentation improvements that don't change API behavior, etc
- NEVER use bold formatting for API names or features (e.g., don't write **Function.getCoverage()**)
- The ONLY exception for bold formatting is **BREAKING**: to mark breaking changes
- Write entries in plain text: `Function.getCoverage()` method for collecting code coverage...

## What NOT to include in changelog
- Documentation improvements (like adding comments, clarifying existing docs)
- Code style changes or formatting
- Internal refactoring that doesn't change public API
- Build system changes that don't affect end users
- Test improvements
- README updates
- Configuration file changes

## Workflow

1. **FIRST**: Determine if the change warrants a changelog entry based on the guidelines above
2. If it does NOT warrant an entry, politely decline and explain why
3. If it does warrant an entry: Add or update the changelog entry
4. Ask if the changes look good. If there is feedback, listen to feedback, proofread work, and update accordingly
5. Once approved or if no feedback is provided, ALWAYS create a git commit:
   - Run `git add CHANGELOG.md`
   - Run `git commit -m "Update CHANGELOG"`
   - Do NOT use any other commit commands - use these exact commands
6. Report back confirming the changelog was updated and committed