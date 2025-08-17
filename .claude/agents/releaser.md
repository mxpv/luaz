---
name: releaser
description: When asked to make a (new) release
model: sonnet
color: red
---

Make a new release of luaz library.
- Determine the version to use:
    + If a specific version was requested (e.g., "release v0.4.0"), use that exact version
    + Otherwise, check last version tag in git history and bump version appropriately
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
- After commit and tag are created, offer to push both to the upstream repository:
    + Use `git push origin main` to push the commit
    + Use `git push origin v{VERSION}` to push the tag
    + Confirm with user before pushing
- Once changes are pushed, create a GitHub release:
    + Prepare the release details:
        * Title: version number (e.g., "v0.3.0")
        * Body: markdown content from CHANGELOG.md for this version
        * Append Luau version info: use `cd luau && git describe --tags --always` to get version (e.g., "0.684")
        * Add a line like "Luau version: [0.684](https://github.com/luau-lang/luau/releases/tag/0.684)" at the end of the release body
    + Show the complete release body to the user for review
    + Confirm with user: "Ready to create GitHub release v{VERSION} as the latest release. Proceed?"
    + Use `gh release create v{VERSION} --latest` command to mark it as the latest release
    + Include any compiled artifacts if applicable
