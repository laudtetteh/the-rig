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

When the request spans multiple issues or multiple PRs, initialize a first-class
batch ledger using the `SPRINT_WORKFLOW.md` **Batch state model**. Preserve the
N-issues-to-M-PRs mapping explicitly; do not rely on conversation order, branch
names, or "same sprint" wording as the durable state.

When tracker access is available through documented public tools, collect a
versioned `sprint-tracker-evidence/v1` document. Otherwise state the limitation;
do not fabricate parity or inspect provider-private state.

## Invoke

Call `rig sprint audit|plan|status --json`, render its result, and obtain every
approval required by `SPRINT_WORKFLOW.md`. Pass the exact #409 root context
already established by hooks. Do not resolve sprint identity from conversation,
branch, PID, title, transcript, or singleton state.

Before launch, produce the Dependency Surface Audit required by
`SPRINT_WORKFLOW.md`: upstream inputs, downstream dependents, generated
artifacts, install/upgrade paths, cross-agent parity, persistent state, and
validation hooks for each ticket or lane. If that audit changes ordering,
ownership, or shared-file exclusivity, revise the plan and get fresh approval.

## Execute

After plan approval, delegate task execution through existing `/run` and `/ship`
gates. Apply #376 validation cards before commits. Never treat sprint approval as
commit, push, PR, merge, release, tracker-write, or destructive authorization.

For multi-issue PRs, require `/ship` to verify that the PR body closes every
intended issue. For issues split across multiple PRs, keep earlier PRs from
auto-closing the issue unless that partial closure is explicitly intended.

When delegating review or validation work, explicitly tell workers not to run a
local full `bats tests/` suite unless the coordinator grants an exception. Long
validation commands should run as foreground tool calls; a worker waiting on one
must report the exact command and tool/session identifier and must not start a
duplicate run while the prior run is active.
