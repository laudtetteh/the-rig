# Command: /sprint

> **Work-mode adapter:** preserve the canonical lifecycle, approvals, and task
> checkpoints below.

Use `.rig/processes/WORK_MODES.md` for the shared lifecycle and
`.rig/processes/SPRINT_WORKFLOW.md` as the sole sprint-specific contract.
This file is a thin Claude adapter.

## Intake

Collect the requested task slugs/issue refs or `--all`, desired mode
(`audit-only`, `plan-only`, `repair-and-plan`, or `resume`), and an explicit
sprint ID for resume. Resolve `$RIG_DIR` through `.rigpath`.

When tracker access is available through documented public tools, collect a
versioned `sprint-tracker-evidence/v1` document. Otherwise state the limitation;
do not fabricate parity or inspect provider-private state.

## Invoke

Call `rig sprint audit|plan|status --json`, render its result, and obtain every
approval required by `SPRINT_WORKFLOW.md`. Pass the exact #409 root context
already established by hooks. Do not resolve sprint identity from conversation,
branch, PID, title, transcript, or singleton state.

## Execute

After plan approval, delegate task execution through existing `/run` and `/ship`
gates. Apply #376 validation cards before commits. Never treat sprint approval as
commit, push, PR, merge, release, tracker-write, or destructive authorization.
