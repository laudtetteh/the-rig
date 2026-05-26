# Context snapshot

> **This file is gitignored.** It lives on disk only — never committed.
> Overwrite it (never delete it) at the end of every session.
> A new session reads this first to orient without needing a full conversation recap.
>
> **Staleness check:** The session start instruction loads this file only if it is
> fresh (written within the last session). The `Last updated:` line at the top of
> the template is how the agent determines freshness — always fill it in.

---

## How to write this file

At session end (or before an anticipated context reset), overwrite this file with:

1. **Where we are** — one paragraph on current project state
2. **Merged PRs** — full list with PR number and one-line description
3. **Open PRs** — any branches currently in review or draft
4. **What's next** — backlog in priority order
5. **Key decisions** — architectural or process decisions that must carry forward
6. **Known footguns** — anything the next session should watch out for
7. **Environment notes** — local setup quirks, credentials locations, port assignments

---

## Template

```markdown
**Last updated:** [YYYY-MM-DD HH:MM] — [session description, e.g. "after merging PR #12"]
**Session name:** [set by /session-name, or blank if unnamed]

---

## Where we are

[One paragraph: what was just built, what state the project is in, what the agent should know immediately.]

---

## Merged PRs

| # | Title | Branch |
|---|---|---|
| [N] | [title] | [branch] |

---

## Open PRs

- PR #[N] — [title] — [status: draft / in review / ready to merge]

---

## What's next (priority order)

1. [P0: highest priority task]
2. [P1]
3. [P2]

---

## Key decisions

- [Decision and why it was made]
- [Decision and why it was made]

---

## Known footguns

- [Thing that bit us and how to avoid it]

---

## Environment notes

- [Local setup detail, port, credential location, etc.]
```
