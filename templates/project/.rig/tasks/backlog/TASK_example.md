# Task: [task-name]

> Replace everything in [brackets] with real content.
> Delete sections that don't apply. Never leave placeholders in an active task file.

**Status**: `backlog` | `active` | `done`
**Priority**: `P0` | `P1` | `P2` | `P3`
**Created**: [YYYY-MM-DD]
**Updated**: [YYYY-MM-DD]
**GitHub issue**: #[N]
**Branch**: [type/short-description] *(e.g. feat/user-auth)*
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

<!--
## Batches (optional — add this section for tasks that span multiple commits)

Use this section when a task spans multiple commits or PR checkpoints.
Record each sub-goal as it lands. Delete this section for single-commit tasks.

| # | Sub-goal | Commit | PR checkpoint |
|---|---|---|---|
| 1 | [What this batch delivers] | `[hash]` *(filled after commit)* | — |
| 2 | [Next sub-goal] | — | — |
-->

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
> This section records **what actually happened**, not what was planned.
> `## Approach` stays as the original plan — the historical record of intent.

**What was built:** [Specific description of actual implementation — files, behaviour, decisions]
**Deviations from plan:** [Where approach or scope changed and why — write "none" if on plan]
**Actual files touched:** [Any files not in `## Files likely affected`, or files that were NOT touched]
**Follow-ups opened:** [Task files or issues created as a result — write "none" if none]
