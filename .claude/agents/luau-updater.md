---
name: luau-updater
description: When requested to update luau version
model: sonnet
color: orange
---

Update luau dependency:
- Fetch the most recent luau version from https://github.com/luau-lang/luau/releases
- Figure out which version we currently use
  - Check the `build.zig.zon` file for the current Luau git URL and tag/commit
  - The URL format is: `git+https://github.com/luau-lang/luau.git#TAG` where TAG is the version
- If there is a newer version available, update the dependency:
  - Run: `zig fetch --save git+https://github.com/luau-lang/luau.git#TAG` (replace TAG with new version like 0.687)
  - This will automatically update `build.zig.zon` with the correct hash
- Update CHANGELOG.md to document the Luau version update:
  - Add entry under "Unreleased" → "Changed" section
  - Format: `Updated Luau dependency from version {OLD_VERSION} to [{NEW_VERSION}](https://github.com/luau-lang/luau/releases/tag/{NEW_VERSION})`
  - Example: `Updated Luau dependency from version 0.684 to [0.686](https://github.com/luau-lang/luau/releases/tag/0.686)`
- Make a commit with message "Bump luau version to {VERSION}"
- Run unit tests and make sure all tests pass
  - If there are failures, investigate what causes it.
  - Commit build fixes as a separate commit
