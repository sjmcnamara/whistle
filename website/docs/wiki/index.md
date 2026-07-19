# Whistle Wiki

This is the working knowledge base for Whistle — the practical stuff that doesn't fit in the README and doesn't belong in the source. If you're here to understand the project rather than to use the app, you're in the right place.

## Start here

| Page | What it covers |
|------|----------------|
| [Architecture](Architecture.md) | How the codebase is laid out, what each service does, how encryption composes |
| [Protocol Specification](PROTOCOL.md) | Wire-level reference: event kinds, payload schemas, URL schemes |
| [Join and Invite Flow](Join-and-Invite-Flow.md) | All the ways someone can be brought into a group |
| [Release Checklist](Release-Checklist.md) | What to do when cutting a version |
| [Testing and CI](Testing-and-CI.md) | How to run the test suites locally and what CI gates on |

## Purpose

This wiki captures practical, high-signal project knowledge that helps contributors move quickly:

- How the app is structured
- How critical user flows work
- How to run and validate tests
- How to debug common failures
- How to ship releases safely

## Contributing to the wiki

- Keep pages concise and operational — prefer concrete commands and code references over prose
- Link to source files when describing behaviour (`Sources/Services/MotionService.swift`)
- Update wiki pages in the same PR as code changes when the behaviour changes
- If something in here is wrong, fix it; if something is missing, add it
