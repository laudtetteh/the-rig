# Release verification gates

The hosted CI workflow is authoritative for release verification. A release
candidate is not ready until the complete Bats suite, shell/static checks, the
security gate, and the focused recovery checks are green. GitGuardian remains an
additional hosted secret-scanning gate; it is not replaced by local tooling.

The focused recovery checks cover the public guarantees that must survive
upgrades and interrupted operations:

- session diagnostics redact native provider identifiers;
- private evidence rejects symlinks and unsafe permissions;
- normal runtime resolution does not inspect provider-private SQLite, indexes,
  rollout files, or transcript formats;
- upgrade work is atomic where possible, reports interrupted state, and exposes
  rollback or repair instructions rather than silently continuing;
- logs, manifests, backups, and reports redact secrets and private provider
  state;
- shell syntax and ShellCheck checks pass before a release candidate is cut;
- manifest provenance, stealth status, manifest mode/hash, stale manifest
  entries, and documented upgrade-pattern checks are verified via
  `bin/rig doctor`; keep the documented gate table in `docs/customizing.md`
  synchronized with the current `doctor()` implementation;
- agent-driven callers (`agent-plan`/`agent-upgrade`) get a JSON result with
  exit code 3 on any unresolved conflict, including a future/bogus manifest
  `base_revision`.
- every completed upgrade-family mutation writes a durable, redacted report
  (`upgrade-reports/YYYYMMDD_HHMMSS_PID.json`), and `agent-plan` writes none;
- `rig upgrade rollback` can undo one completed upgrade from that report, and
  refuses any path edited since, any wrong-type or symlinked destination, any
  path escaping its storage root, and any unverifiable backup.
- post-release single-project pilots classify any `agent-upgrade` exit 3 before
  declaring rollout blocked: true Rig-owned convergence conflict,
  preserve-only/user-owned classification bug, stale/future manifest issue,
  symlink/wrong-type conflict, or unknown/manual investigation. The delegated
  pilot agent stays conservative and does not repair downstream files unless
  explicitly instructed after coordinator classification.

## Required hosted checks

The required checks are:

1. `bats test suite` — complete `bats tests/` coverage, sharded.
2. `bats test suite (shard coverage check)` — verifies every `tests/*.bats`
   file was claimed by some shard. Sharding's own failure mode is a file
   silently belonging to no shard and therefore never running.
3. `shell and static checks` — Bash syntax, Python compilation, ShellCheck, and
   whitespace/error checks.
4. `security and recovery gates` — focused path, symlink, permission,
   redaction, and upgrade-recovery regression tests plus gitleaks.
5. GitGuardian — hosted secret scanning for the repository and pull request.

If an upgrade is interrupted by a failed write, permission error, process exit,
or disk-full condition, the operator must preserve the failure output, inspect
the generated summary and backup state, and use the documented repair or
rollback path. A rerun is acceptable only after the interrupted state is
resolved and the result is idempotent. Do not delete backups or manifests as a
shortcut around a conflict.

## Downstream upgrade policy classes (issue #564)

Narrow convergence tests once passed while every generic customized Rig-owned
file still refused, and no gate exercised a *historical* downstream state. A
v1.29.0 rollout then stopped on a real project whose 16 customized Rig-owned
files were tracked only in the legacy flat manifest — a shape no test covered.

A release that touches upgrade behaviour, the report schema, rollback, or
installer mutation paths must therefore keep these fixture classes green. One
fixture per class, not an unbounded matrix:

| Policy class | Fixture |
|---|---|
| Historical base, legacy flat manifest, no provenance | `tests/test_upgrade_historical_base.bats` |
| Convergence and true-conflict refusal | `tests/test_convergence_engine.bats` |
| Durable report schema and redaction | `tests/test_upgrade_reports.bats` |
| Completed-upgrade rollback and its refusals | `tests/test_upgrade_rollback.bats` |
| Agent contract: zero-write plan, exit 3, stealth idempotence | `tests/test_upgrade_agent_contract.bats` |
| Stealth/external manifest layouts, wrong-type and symlink refusal | `tests/test_stale_manifest_layouts.bats` |
| Mutation scope confinement during upgrade prepare | `tests/test_upgrade_prepare_mutation_scope.bats` |
| Interrupted transaction recovery (`install.sh --recover`) | `tests/test_upgrade_recovery.bats` |

Two properties of the historical-base fixture class are load-bearing:

- **CI must fetch tags.** The resolver proves a merge base by matching the
  manifest's recorded hash against template content at release tags. A default
  shallow checkout has no tags, so the resolver refuses, convergence silently
  degrades to refuse-always, and these tests pass locally while failing in CI
  for an unrelated reason. The Bats job sets `fetch-depth: 0` for this.
- **A live/adversarial pilot is still required** for releases in this area.
  Automatic convergence has a real ceiling: on the 4Culture-shaped blocker it
  resolves 5 of 16 files, with the other 11 genuine overlapping edits reported
  per hunk. "Some files still refuse" is the designed outcome, not a failure —
  but it means a pilot, not a green suite, is what tells you a rollout will
  land.

Before opening a release PR, run the focused Bats file locally and review the
complete staged diff. Hosted CI and GitGuardian, not a partial local run, are
the authoritative release gates.
