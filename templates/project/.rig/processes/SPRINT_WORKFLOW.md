# SPRINT_WORKFLOW

This is the canonical audit-to-close workflow for sprint mode. Claude `/sprint`
and Codex `$sprint` are thin adapters; all deterministic audit, parity, conflict,
durability, and resume behavior comes from `rig sprint`.

## Lifecycle

Follow `inspect -> plan -> approve -> execute -> validate -> ship -> closeout`
and the statuses in `WORK_MODES.md`. A sprint coordinates task cards; it never
replaces their checkpoints, operating modes, validation, or shipping gates.

## 1. Audit

Collect tracker evidence only through documented public tools and serialize the
versioned `sprint-tracker-evidence/v1` shape. If access is unavailable, record
that limitation; never infer tracker parity from local cards. Run:

```bash
rig sprint audit --all --tracker-evidence "$EVIDENCE" --json
```

Review task schema, tracker/local parity, dependencies, duplicates, file scope,
source freshness, and confidence. Repairs are proposals. Task metadata,
dependency, scope, duplicate-fold, lifecycle, and tracker changes require the
separate approval mandated by `WORK_MODES.md`.

## 2. Plan and approve

Generate a no-write preview first:

```bash
rig sprint plan --all --mode plan-only --json
```

Present waves, typed conflict/dependency edges, and every non-execution lane:
blocked, decision, research, oversized, release, deferred, and cancelled. Obtain
explicit plan approval, then repeat with `--write --approval-token TOKEN`.
Planning approval authorizes no task implementation, commit, push, PR, merge,
release, destructive action, or tracker write.

## 3. Launch and execute

Before launch, re-audit actual scopes and dependencies. Drift that changes
ownership/order creates a superseding plan revision and requires approval.
Launch only from an exact #409 root session; subagents and side conversations
cannot approve, launch, or close. Do not introduce another resolver.

Delegate each approved item to its unchanged task card and `/run` lifecycle.
Respect exclusive shared-file lanes and worktrees. Checkpoint task and sprint
state on pause, blocker, deviation, or mode transition.

## 4. Validate and ship

Each task uses `SHIP_WORKFLOW.md`. In particular, #376 requires 1–5 live steps
with Setup, Command/action, Expected, Cleanup, actual agent result, explicit
skips/residual risk, and a separate commit approval. Sprint evidence can
aggregate those cards but never replace them. Hosted CI/security gates and
merge/release authorization remain task/project gates.

## 5. Resume and close

Resume only with an explicit sprint ID:

```bash
rig sprint status --sprint "$SPRINT_ID" --refresh --json
```

Reconcile the current immutable revision with task checkpoints, repository/PR/CI
state, and fresh tracker evidence. Never select by branch, PID, title, singleton,
or transcript. Close only when every item is terminal with exact resume points,
fresh parity is recorded, and the exact #409 root acknowledges only its own wrap
obligation and the matching post-merge SHA through the shared obligation API.

No merge or release is automatic.
