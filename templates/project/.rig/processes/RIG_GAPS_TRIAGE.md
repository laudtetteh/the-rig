# RIG_GAPS_TRIAGE

This is the validated machine-wide triage workflow for Rig gap collection.
Claude `/rig-gaps --triage` and Codex `$rig-gaps --triage` are thin adapters;
this process defines the validation, dedupe, scoping, priority, privacy, and
ticket-readiness contract.

## Lifecycle

Follow `collect -> normalize -> validate -> dedupe -> classify -> prioritize -> report`.
The workflow is read-only until the user explicitly asks to create tickets or mark
source gap entries submitted.

## 1. Collect

Run the provider's collect command first — Claude `/rig-gaps --collect` or Codex
`$rig-gaps --collect` — or reuse a fresh collector report from the same calendar
day. Collection covers canonical `memory/RIG_GAPS.md` files under machine-wide
Rig project storage and excludes backups. Preserve source project, scope, title,
date, category, severity, workflow, observation, and suggested fix for every
candidate.

Do not write under any source project's Rig memory during triage. Missing or
invalid `**Scope**` remains `needs-review`; do not infer `rig-core` from old
entry wording alone.

## 2. Normalize

Create a candidate table with:

- `candidate_id`: stable slug for the group
- `sources`: source project names and entry dates
- `scope`: `rig-core`, `project`, or `needs-review`
- `title`: normalized issue-like title
- `evidence`: short references to representative observations
- `affected_surfaces`: command, process, hook, installer, docs, memory, or project-local
- `confidence`: high, medium, or low

Normalize names and punctuation, but preserve the original entry text in the
report appendix so no project-specific evidence is lost.

## 3. Validate Against Current Rig Source

For every candidate, inspect only the relevant current source files. Avoid broad
sweeps. Record whether the gap is still reproducible, already fixed, stale,
project-local, or lacking enough evidence.

Validation must identify the exact source surface that owns the behavior:
command adapter, canonical process, `bin/rig`, hook, installer, test helper,
template, docs, or downstream project configuration.

## 4. Dedupe Against Tracker State

Before creating or recommending any new issue, cross-check candidate groups
against open and closed tracker issues using documented public tracker tools.
Compare title, affected surface, observed behavior, and acceptance criteria; do
not rely on exact-title matches only.

Classify every candidate as exactly one of:

- `file-new`: valid Rig-core gap with no matching open or closed issue
- `covered-open`: matching open issue exists; add evidence there instead
- `covered-closed/stale`: matching closed issue or current source proves it fixed
- `project-local`: belongs to one project, not Rig core
- `needs-more-evidence`: plausible but not actionable from current evidence

## 5. Scope And Prioritize

Assign priority by risk and unblock value:

- `P0`: data loss, security boundary, destructive automation, or broken install/upgrade
- `P1`: workflow dead-end, false confidence, or repeated manual recovery
- `P2`: validated friction affecting multiple projects or recurring maintainer time
- `P3`: polish, wording, or low-frequency ergonomics

Group semantically related `file-new` candidates into one actionable ticket when
they share the same owning surface and acceptance criteria. Split candidates when
one fix would cross unrelated ownership boundaries or weaken verification.

## 6. Report

Produce a prioritized actionable report:

```markdown
# Rig Gaps Triage — YYYY-MM-DD

## Summary
- Source projects scanned:
- Candidate groups:
- file-new:
- covered-open:
- covered-closed/stale:
- project-local:
- needs-more-evidence:

## Recommended Tickets
1. P2 — title
   - Classification: file-new
   - Source evidence: project/date list
   - Current-source validation: files checked and result
   - Existing-issue check: open/closed searches and result
   - Acceptance criteria:

## Covered Or Stale
- title — classification, matching issue or source proof

## Appendix
- Representative original entries
```

The report must be suitable for manual issue creation or review. It must not
claim source gap entries were submitted unless the user explicitly approved a
separate mutation step.

## 7. Optional Mutations

Ticket creation and source-log marking are separate approvals:

- **Create issues:** use repository issue templates when present, include
  grouped source evidence, current-source validation, existing-issue check, and
  acceptance criteria.
- **Mark submitted:** mutate source `RIG_GAPS.md` files only when the user
  explicitly asks; mark only entries represented in created or updated tracker
  issues, and include the issue number in the submitted marker when practical.

Never combine read-only triage with mutation under one implied approval.
