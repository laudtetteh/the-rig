# Command: /doc-list

Show the documentation index for this project without loading full doc files.

## What this does

> **RIG_DIR resolution (stealth mode):** Resolve `.rig/` path before reading any files.
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> if [[ -f "$REPO/.rigpath" ]]; then
>   RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
> else
>   RIG_DIR="$REPO/.rig"
> fi
> ```
>
> **DOCS_DIR resolution:** Stealth installs keep docs under `$RIG_DIR/docs/`; in-repo
> installs keep them at `$REPO/docs/`. Resolve before reading any doc paths:
> ```bash
> if [[ -f "$REPO/.rigpath" ]]; then
>   DOCS_DIR="$RIG_DIR/docs"
> else
>   DOCS_DIR="$REPO/docs"
> fi
> ```

1. Read `$DOCS_DIR/INDEX.md`.
   - If absent: say "No `docs/INDEX.md` found. Create one with a one-liner per file in `docs/` — see `docs/INDEX.md` in The Rig repo for the format."
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
- **Do not display `$DOCS_DIR/features/README.md` here.** Feature docs are a separate
  system managed by `/doc-feature` and `/feature-context` — `/doc-list` shows the
  general docs index only.
