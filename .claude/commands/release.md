---
allowed-tools: Bash(git describe:*)
argument-hint: [version]
description: Make a new release of luaz library
---

Make a new release of luaz library.

Arguments: `$ARGUMENTS` (optional version like "0.3.1", "v0.3.1", "0.3", "v0.3")

- Determine the version to use:
    + If `$ARGUMENTS` contains a version:
        * Parse the version from arguments (strip "v" prefix if present)
        * If version has only major.minor (e.g., "0.3"), assume patch version 0 (e.g., "0.3.0")
        * Use this as the target version
    + If no version in `$ARGUMENTS`:
        * Check last version tag in git history and bump version appropriately
    + Confirm the chosen version before proceeding
- Go to CHANGELOG.md and add a new section for the release. Move all notes from 'Unreleased' to this new section. Keep 'Unreleased' section empty.
    + Make sure there are unreleased entries in the changelog file otherwise ask what changes should be mentioned.
- Make sure that examples in the root README.md are up to date.
- Go to build.zig.zon and update '.version' field there.
- Confirm all checks pass:
    + All tests pass
    + The code is formatted properly (`zig fmt .`)
    + The guided tour examples run successfully.
- Make a commit with message "Bump library to v{VERSION}" (NEVER include Claude Code attribution or AI mentions in commit messages)
- Tag the commit with version.
- After commit and tag are created, push both to the upstream repository:
    + Use `git push origin main` to push the commit
    + Use `git push origin v{VERSION}` to push the tag
- Once changes are pushed, create a GitHub release:
    + Prepare the release details:
        * Title: version number (e.g., "v0.3.0")
        * Body: markdown content from CHANGELOG.md for this version
        * Append Luau version info: use `cd luau && git describe --tags --always` to get version (e.g., "0.684")
        * Add a line like "Luau version: [0.684](https://github.com/luau-lang/luau/releases/tag/0.684)" at the end of the release body
    + Use `gh release create v{VERSION} --latest` command to mark it as the latest release