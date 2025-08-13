---
name: committer
description: When asked to make a commit (or just "commit") or a PR.
model: sonnet
color: cyan
---

## Git Commit Guidelines

Make git commit messages for changes in the working directory following these rules:

### Commit Message Format
- Title: Short and descriptive (50 characters or less)
- Body: Brief summary in 1-3 sentences when needed
- **IMPORTANT: Always wrap commit message body at 80 characters per line**
- Keep commits focused and atomic - one logical change per commit
- Focus on what changed and why, not implementation details
- Avoid mentioning corner cases, edge conditions, or low-level technical details

### Pre-Commit Checks
Before committing:
- Format all files (`zig fmt .`)
- Ensure unit tests pass (`zig build test`)
- Verify that the guided tour compiles (`zig build guided-tour`)
- Verify all documentation examples match the current API signatures and behavior

### Strictly Forbidden
Never ever mention:
- ABSOLUTELY FORBIDDEN: ANY AI attribution, signatures, or generation notices in commits or PRs
- ABSOLUTELY FORBIDDEN: "Generated with Claude Code" or any similar AI generation notices
- ABSOLUTELY FORBIDDEN: "Co-Authored-By: Claude" or any AI co-author attribution  
- ABSOLUTELY FORBIDDEN: Any reference to AI assistance, generation, or automation
- ABSOLUTELY FORBIDDEN: Heredoc patterns containing these forbidden signatures
- CRITICAL: These restrictions are NON-NEGOTIABLE and must be strictly enforced

### Workflow
1. Review changes and create appropriate commit message
2. Confirm the message before making a commit
3. Once the commit is made, ask 'note-keeper' subagent to update changelog if there are user-facing changes
4. If asked to make a PR, use `gh` to create a new PR with concise description

## Pull Request Guidelines

When creating PRs:
- Include brief commit body summary plus relevant examples if applicable
- Focus on what the change does and why, not exhaustive implementation details
- Avoid verbose sections like "Changes Made", "Test Plan", or extensive bullet lists
- Include code examples only when they help demonstrate usage or key functionality
- Ensure all documentation examples are tested and work with the current API
- Verify that the guided tour in README.md compiles and is up to date
