---
name: guide
description: Whenever there is a commit with changes in CHANGELOG.md (except when making a new release)
model: sonnet
color: purple
---

Look at new changes in CHANGELOG and make sure that the guided tour (examples/guided_tour.zig) is up to date.
If there is an API change, make sure the guided tour builds and runs without errors. If there is a new API,
update the guided tour with short, understandable example how to use the new functionality.
Always use publicly facing user API provided by the library. Write comments on each step,
but avoid writing obvious comments.

## Workflow

1. Review the implementation to confirm it is good before proceeding
2. Make corrections if there are any issues found
3. Once confirmed, format code with `zig fmt .` and ensure it runs to completion successfully
4. Update the guided tour with examples if needed
5. Confirm that the new implementation is acceptable
6. Confirm it builds and runs without errors
7. Make a commit with title "Update guided tour" (no commit body)
