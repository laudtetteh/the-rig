# WORK_MODES

This is the canonical orchestration contract for project-, task-, and
sprint-driven work. Agent commands are adapters: they may collect mode-specific
inputs, but they must preserve this lifecycle, state vocabulary, approval model,
and resume behavior.

## Shared lifecycle

Every mode moves through the same ordered phases:

`inspect -> plan -> approve -> execute -> validate -> ship -> closeout`

Phases may be resumed but not silently skipped. A mode records one of these
statuses: `proposed`, `ready`, `active`, `blocked`, `partial`, `complete`, or
`cancelled`.

| Phase | Required output |
|---|---|
| inspect | Inputs, current repository state, constraints, and dependencies |
| plan | Scope, affected paths, acceptance criteria, and verification plan |
| approve | User decision authorizing launch or requested planning repairs |
| execute | Changes and checkpoints governed by each task's operating mode |
| validate | Lint, tests, and live-behavior evidence, including failures |
| ship | The separately governed shipping workflow and its approvals |
| closeout | Final status, remaining work, and an unambiguous resume point |

`ship` remains a distinct workflow. This contract invokes it; it does not
redefine or weaken its gates.

## Modes and authoritative artifacts

### Project mode

- **Inputs:** `PROJECT_BRIEF.md`, repository maturity, constraints, and tracker
  configuration.
- **Outputs:** a configured `CLAUDE.md`, an initial backlog of task cards, and
  an approved choice to stop, launch one task, or launch a sprint.
- **Adapter:** `/kickoff`.

Project mode may operate alone and stop after backlog creation. It never treats
backlog creation as authorization to execute every task.

### Task mode

- **Inputs:** one task request or existing task card.
- **Outputs:** one task card conforming to the shared schema, implementation and
  validation evidence, and a terminal or resumable status.
- **Adapters:** `/task` creates/configures; `/run [slug]` executes.

The task card is the source of truth for scope, approvals, operating mode, and
resume state. A task may run alone or be embedded unchanged in a sprint.

### Sprint mode

- **Inputs:** a named or discovered set of task cards.
- **Outputs:** an approved conflict/dependency plan, per-task results, and a
  sprint closeout that identifies completed, partial, blocked, and cancelled
  work.
- **Adapter:** `/sprint`.

Sprint mode coordinates tasks; it does not replace their cards or operating
modes. Each embedded task follows the shared lifecycle and its own shipping
gate.

## Supported transitions

| From | To | Contract |
|---|---|---|
| project | task | Select or create one card, approve its plan, then use task mode. |
| project | sprint | Select backlog cards, approve the sprint plan, then launch. |
| task | sprint | Checkpoint the task first; include its card without copying state. |
| sprint | task | Checkpoint sprint results; isolate one incomplete card explicitly. |
| task | embedded task | `/run` and `/sprint` use the same card and lifecycle. |

No transition implies execution approval. The receiving mode must reach its
own `approve` phase.

## Approval and mutation boundaries

Explicit approval is required before:

1. launching a project-derived task or sprint plan;
2. repairing task metadata, dependency edges, or declared file scope;
3. accepting a scope change after launch;
4. making external mutations such as tracker, remote branch, or PR changes; or
5. performing irreversible or materially destructive work.

After launch, the task's `## Operating mode` controls ordinary implementation
decisions and check-ins. It cannot waive the boundaries above. Read-only
inspection and validation are allowed while preparing a proposal.

## Checkpoint and resume contract

Do not create a second global work-state database. Persist state in the artifact
that owns it:

- project decisions and generated backlog live in `PROJECT_BRIEF.md`,
  `CLAUDE.md`, and task cards;
- task state lives in its task card's `## Work checkpoint`;
- sprint state lives in its plan and the referenced task cards; and
- cross-session orientation lives in `CONTEXT_SNAPSHOT.md`.

Before pausing, switching modes, or handing work to another agent, record:

- mode, phase, and status;
- last completed step and validation evidence;
- remaining work and exact next action;
- blocker, owner, and unblock condition when blocked;
- approved scope changes; and
- branch/worktree or PR identity when applicable.

On resume, inspect the owning artifact and repository state, reconcile any
drift, and continue from the recorded phase. Never infer completion from a
commit, branch, or PR alone.

## Blocking, cancellation, and partial completion

- **blocked:** preserve completed work, name the blocker and unblock condition,
  and do not advance the phase.
- **cancelled:** record who cancelled, why, external side effects, and cleanup;
  do not silently delete useful checkpoints.
- **partial:** list completed acceptance criteria, failed or deferred criteria,
  residual risk, and the supported resume or isolation transition.
- **complete:** requires acceptance criteria and applicable validation/ship gates
  to be satisfied, not merely implementation ending.

## Governance invariants

All modes use the task schema in `TASK_example.md`, resolve external `.rig/`
through `.rigpath`, preserve protected-path rules, keep planning distinct from
execution approval, and report overlap rather than broadening declared scope.
