# Command: /rig-audit

Review Rig-authored work for accuracy, completeness, and path clarity, then repair verified local findings.

## What this does

Default to the current session scope. Accept only the optional `--full` flag. Resolve `$RIG_DIR` from the repository `.rigpath` before reading or writing any Rig memory or task path.

## Step 1 — Establish scope and evidence

- **Session scope (default):** inspect repository files changed since this session started; Rig memory, task, and documentation files under `$RIG_DIR` edited since the exact session's `started_at`; and helper scripts created under `$RIG_DIR` during this session. Read the exact session record with `rig session resolve --json`. If the session is not exact, report the limitation and do not use another session's timestamps or files.
- **Full scope (`--full`):** inspect active, backlog, and done task cards; live open GitHub issues and PRs; README files and repository docs; `$RIG_DIR/docs/`; shipped and local commands/skills, processes and rules; `CLAUDE.md` and `AGENTS.md`; and Claude/Codex parity using `bin/rig doctor`.

For every claim, open the cited current file or live tracker item and reproduce the behavior when it is technical. Check closed issues for duplicates. Treat older reports and subagent findings as leads, not evidence. Include install and upgrade behavior, Claude/Codex parity, memory/session contracts, and CI effects when those surfaces are in scope.

## Step 2 — Produce the audit table

For each item report:

| Item | State | Evidence | Repair |
|---|---|---|---|

Use `valid`, `stale`, `uncertain`, or `out of scope`. Name exact paths, issue/PR numbers, and reproducible behavior. Flag ambiguous `.rig/...` paths that do not say whether they mean the repository or resolved `$RIG_DIR`.

## Step 3 — Fix verified local findings

Apply verified, in-scope documentation and memory corrections in the selected scope, then report every path changed. Code changes must follow the project's task, test, review, and ship requirements; do not silently expand into application code. Never change a GitHub issue, PR, label, release, or merge without the existing approval gate. If a question arises while continuing, append it to the exact session's decision ledger with `bin/rig session decision append`; close it only after the user answers.

When a fix needs approval, touches a path outside the selected scope, or cannot be reproduced, leave it unchanged and state the exact next step. Do not write a dated sprint revision as part of this audit.
