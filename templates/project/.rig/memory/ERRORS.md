# Errors and pitfalls log

> Every time the agent (or you) hits a non-obvious bug, wrong assumption, or footgun —
> log it here so it never happens twice.
>
> Updated immediately when something goes wrong. Never defer — the detail is freshest now.

---

## Format

```markdown
## [YYYY-MM-DD] — [Short title]

**Symptom**: What was observed / what broke
**Root cause**: What was actually wrong
**Fix**: What change resolved it
**Watch for**: Related areas that could have the same issue
```

---

<!-- Add new entries below this line, newest first -->

## Example entry

## [YYYY-MM-DD] — Example: dependency not found after container rebuild

**Symptom**: `Module not found` error in the running container after adding a new package.

**Root cause**: Docker anonymous volumes shadow `node_modules` (or the equivalent package dir).
Rebuilding the image installs the package into the new image layer, but the running container
keeps using the stale anonymous volume — the new package is never visible.

**Fix**: `docker compose down && docker compose up -d` (recreates the volume) or
`docker compose up -d -V` (the `-V` flag forces anonymous volume recreation).

**Watch for**: Any time you add a dependency and the container is already running.
Always verify with a test import after any dependency change.
