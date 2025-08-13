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
Before committing:
- Confirm that the new implementation is acceptable.
- Confirm it builds and runs without errors.
Once everything confirmed, make a commit with title "Update guided tour"
