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

Before launch, write a **Dependency Surface Audit (DSA)** for every planned
ticket or lane. Use the same dependency-impact terms as `/ship` so planning and
pre-ship evidence line up. The DSA must list:

- **Upstream inputs:** commands, hooks, scripts, schemas, external CLIs, memory
  files, and installed project state the ticket depends on.
- **Downstream dependents:** commands, hooks, docs, tests, install paths, and
  user workflows that consume the likely touched files.
- **Generated artifacts:** Codex skill mirrors, copied templates, manifest
  metadata, helper scripts, and other derived files.
- **Upgrade/install path:** fresh install, existing install, tracking mode,
  Claude-only, Codex-only, and combined agent targets when relevant.
- **Cross-agent parity:** Claude command, Codex skill, `bin/rig`, hooks, and
  canonical process surfaces that must preserve the same contract.
- **Persistent state:** session records, snapshot/progress files, manifests,
  task/sprint state, and external `$RIG_DIR` writes.
- **Validation hooks:** focused tests, command-lint, generated-artifact parity,
  CI/security gates, and live/manual checks.

If the DSA changes ordering, ownership, shared-file exclusivity, or persistent
state risk, revise the sprint plan before launch and obtain fresh approval.

## 3. Launch and execute

Before launch, re-audit actual scopes and dependencies. Drift that changes
ownership/order creates a superseding plan revision and requires approval.
Launch only from an exact #409 root session; subagents and side conversations
cannot approve, launch, or close. Do not introduce another resolver.

Delegate each approved item to its unchanged task card and `/run` lifecycle.
Respect exclusive shared-file lanes and worktrees. Checkpoint task and sprint
state on pause, blocker, deviation, or mode transition.

Delegated workers must run long validation commands as foreground tool calls and
let the harness manage continuation unless the coordinator explicitly asks for a
manual detach. A worker waiting on validation must report the exact command and
tool/session identifier, must not start duplicate validation while that run is
active, and must preserve the project rule that focused local tests are normal
while the full local `bats tests/` suite requires an explicit coordinator
exception. Prompts to review or validation workers must state that constraint
verbatim.

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
