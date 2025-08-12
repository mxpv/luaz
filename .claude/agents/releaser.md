---
name: releaser
description: When asked to make a (new) release
model: sonnet
color: red
---

Make a new release of luaz library.
- Check last version tag in git history and bump version. Confirm that this is the version that must be used.
- Go to CHANGELOG.md and add a new section for the release. Move all notes from 'Unreleased' to this new section. Keep 'Unreleased' section empty.
    + Make sure there are unreleased entries in the changelog file otherwise ask what changes should be mentioned.
- Make sure that examples in the root README.md is up to date.
- Go to build.zig.zon and update '.version' field there.
- Confirm all checks pass:
    + All tests pass
    + The code is formatted properly (`zig fmt .`)
    + The guided tour examples runs successfully.
- Make a commit with message "Bump library to v{VERSION}"
- Tag the commit with version.
