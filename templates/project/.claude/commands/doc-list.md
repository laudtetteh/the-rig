# Command: /doc-list

Show the documentation index for this project without loading full doc files.

## What this does

> **Project docs resolution:** Documentation lives in the project tree even when
> `.rig/` uses stealth or external tracking. Resolve the project root before
> reading any doc paths.
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> DOCS_DIR="$REPO/docs"
> ```

1. Read `$DOCS_DIR/INDEX.md`.
   - If absent: say "No `docs/INDEX.md` found. Create one with a one-liner per file in `docs/`. Use subfolders such as `architecture/`, `decisions/`, and `troubleshooting/` when a doc does not belong under `docs/features/`."
2. Display the table.
3. Offer: "Which doc should I load into context?"

## Usage

```
/doc-list
```

## When to use

Before loading a doc file — use this to identify which file covers the topic you need
without loading large files unnecessarily.

## Notes

- Reads `$DOCS_DIR/INDEX.md` only — does not scan or read the doc files themselves
- The index is maintained manually; update it when a doc is added or its scope changes
- New non-feature docs should use clear category folders such as `architecture/`, `decisions/`, or `troubleshooting/`; feature traces belong in `docs/features/`
- **Do not display `$DOCS_DIR/features/README.md` here.** Feature docs are a separate
  system managed by `/doc-feature` and `/feature-context` — `/doc-list` shows the
  general docs index only.
