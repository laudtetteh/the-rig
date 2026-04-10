# Task: [task-name]

> Replace everything in [brackets] with real content.
> Delete sections that don't apply. Never leave placeholders in an active task file.

**Status**: `backlog` | `active` | `done`
**Priority**: `P0` | `P1` | `P2` | `P3`
**Created**: [YYYY-MM-DD]
**Updated**: [YYYY-MM-DD]
**GitHub issue**: #[N]
**PR**: #[N] *(filled after merge)*
**Depends on**: #[N] *(remove if no dependency)*

---

## Goal

[One sentence: what does this task deliver?]

---

## Context

[Why does this task exist? What problem does it solve? What PR or milestone does it belong to?]

---

## Acceptance criteria

- [ ] [Specific, testable condition — can be verified without interpretation]
- [ ] [Another condition]
- [ ] [Another condition]

---

## Approach

> Written by the agent **before** implementation begins. Approved by the user before any code is written.

1. [Step with file-level specificity — e.g. "Edit `services/auth.py` to add token verification"]
2. [Next step]
3. [Next step]

---

## Files likely affected

- `[path/to/file]` — [what changes and why]
- `[path/to/file]` — [what changes and why]

---

## Out of scope

- [What this task explicitly does NOT do — prevents scope creep]

---

## Prompt history

> Running log of significant prompts and outcomes during this task.

### [YYYY-MM-DD]

**Prompt**: [What was asked]
**Outcome**: [What happened]
**Notes**: [Anything worth remembering for future sessions]

---

## Blockers

- [ ] [Anything preventing progress — remove when resolved]

---

## Operating mode

> Set by the `/task` intake wizard. This is the source of truth for how the agent
> operates on this task. Do not change mid-task without noting it in Prompt history.

| Setting | Value |
|---|---|
| Autonomy | 🌶🌶 Medium (Supervised) |
| Check-ins | Normal |
| Risk tolerance | Balanced |

**In practice:** I'll execute the full plan after you approve it, give you progress
updates at milestones, and flag any change that touches more than 5 files.

---

## Done notes

> Filled in when the task is complete, before moving to `tasks/done/`.

[What was built. Any deviations from the original approach. Follow-up tasks opened.]
