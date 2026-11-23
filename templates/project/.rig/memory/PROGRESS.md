# Progress log

> Running log of completed work. Most recent entry at the top.
> Updated at the end of every task and after every PR merge.
> The post-commit Git hook auto-stubs guarded agent commits. In a hookless install,
> PostToolUse stubs approved visible commits when it sees a matching Git result.
> Expand auto-stubs during wrap-up.
>
> **Trim convention:** keep the 20 most recent entries in this file.
> When `/wrap` detects more than 20 entries, it moves the oldest to
> `memory/PROGRESS_archive.md` (gitignored — disk only, never committed).
> This keeps session startup cost low while preserving full history locally.
>
> **Session-end markers:** `<!-- session-end YYYY-MM-DD HH:MM -->` comments are
> automatically appended by the `stop.sh` hook when the agent finishes a response.
> These are invisible in rendered Markdown and are used by `/wrap` and `/post-merge`
> to determine which PROGRESS entries belong to the current session when suggesting
> a session name. Do not remove them manually.

---

## Format

```markdown
## [YYYY-MM-DD] — [one-line summary] <!-- sid:UUID -->

- [bullet: what was built]
- [bullet: what was verified or tested]
- PR #N merged — branch: type/description
```

Resolve the current exact session with `bin/rig session resolve --json` from the
project root. Use its `anchor` for the `sid:` marker only when `ok: true` and
`confidence: exact`; otherwise stop the session-tagged write and resolve the
session identity first. Do not infer identity from a parent PID or a temporary
sentinel.

---

<!-- Add entries above this line, newest first -->
