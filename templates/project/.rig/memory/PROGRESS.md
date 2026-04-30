# Progress log

> Running log of completed work. Most recent entry at the top.
> Updated at the end of every task and after every PR merge.
> The post-tool hook auto-stubs an entry after each git commit — expand it during wrap-up.
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
## [YYYY-MM-DD] — [one-line summary]

- [bullet: what was built]
- [bullet: what was verified or tested]
- PR #N merged — branch: type/description
```

---

<!-- Add entries above this line, newest first -->
