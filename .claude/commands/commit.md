---
description: Create a git commit following repository guidelines
---

Create a git commit for the current working directory changes following these guidelines:

Arguments: `$ARGUMENTS` (optional additional instructions or context for the commit)

## Commit Message Format
- Title: Short and descriptive (50 characters or less)
- Body: Brief summary in 1-3 sentences when needed
- **IMPORTANT: Always wrap commit message body at 80 characters per line**
- Keep commits focused and atomic - one logical change per commit
- Focus on what changed and why, not implementation details
- Avoid mentioning corner cases, edge conditions, or low-level technical details
- **SPECIAL CASE**: If changes are only in CHANGELOG.md file, the commit message must be exactly "Update CHANGELOG"

## Pre-Commit Checks
Before committing:
- Format all files (`zig fmt .`)
- Ensure unit tests pass (`zig build test`)
- Verify that the guided tour compiles (`zig build guided-tour`)
- Verify all documentation examples match the current API signatures and behavior

## Strictly Forbidden
Never ever mention:
- ABSOLUTELY FORBIDDEN: ANY AI attribution, signatures, or generation notices in commits
- ABSOLUTELY FORBIDDEN: "Generated with Claude Code" or any similar AI generation notices
- ABSOLUTELY FORBIDDEN: "Co-Authored-By: Claude" or any AI co-author attribution  
- ABSOLUTELY FORBIDDEN: Any reference to AI assistance, generation, or automation
- ABSOLUTELY FORBIDDEN: Heredoc patterns containing these forbidden signatures
- CRITICAL: These restrictions are NON-NEGOTIABLE and must be strictly enforced

## Workflow
1. Come up with appropriate commit message
2. Run checks (format, tests, guided tour)  
3. Execute git commit