# Command: /status

Print a project state dashboard: branch, active tasks, backlog, and recent progress.

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

Work through the following in order. Output a clean, scannable dashboard — not walls of text.

### 1. Branch

```bash
git branch --show-current
```

Show: `**Branch:** [name]`

### 2. Active tasks

```bash
ls "$RIG_DIR/tasks/active/" 2>/dev/null
```

For each file found: read the `## Goal` section (first sentence only) and the `**Status**` field.
Format as a bullet list:

```
**Active tasks (N):**
- TASK_foo.md — [one-sentence goal]
- TASK_bar.md — [one-sentence goal]
```

If none: `**Active tasks:** none`

### 3. Backlog

```bash
ls "$RIG_DIR/tasks/backlog/" 2>/dev/null | wc -l
```

Show: `**Backlog:** N task(s)` — count only, no details.

### 4. Recent progress

Read `$RIG_DIR/memory/PROGRESS.md`. Show the last 5 `##` section headings and the first line of body under each:

```
**Recent progress:**
- [section heading] — [first body line]
- ...
```

If the file is absent: skip this section.

### 5. Pending flags

```bash
[[ -f "$RIG_DIR/memory/.wrap-needed" ]] && echo "wrap-needed"
[[ -f "$RIG_DIR/memory/.post-merge-pending" ]] && echo "post-merge-pending"
```

If `.wrap-needed` exists: `⚠️ /wrap needed — last session didn't wrap`
If `.post-merge-pending` exists: `⚠️ /post-merge pending — a merge landed since last run`

If no flags: omit this section.

## Usage

```
/status
```

## When to use

- At the start of a session as a faster alternative to reading full context files
- After a long task to orient before deciding what's next
- When the user asks "where are we?", "what's active?", or "what's in the backlog?"
