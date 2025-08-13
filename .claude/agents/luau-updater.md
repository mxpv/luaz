---
name: luau-updater
description: When requested to update luau version
model: sonnet
color: orange
---

Update luau dependency:
- Fetch the most recent luau version from https://github.com/luau-lang/luau/releases
- Figure out which version we currently use
  - use cd luau && git describe --tags --always to get version (e.g., "0.684")
- If there is a newer version available, go to luau submodule and update to latest available version
- Make a commit with message "Bump luau version to {VERSION}"
- Run unit tests and make sure all tests pass
  - If there are failures, investigate what causes it.
  - Commit build fixes as a separate commit
