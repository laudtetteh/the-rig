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
- manifest provenance and stealth-status are verified via `bin/rig doctor`'s 5
  postflight gates (`manifest_provenance`, `stealth_status`,
  `manifest_mode_hash`, `stale_manifest_entries`, `idempotence`);
- agent-driven callers (`agent-plan`/`agent-upgrade`) get a JSON result with
  exit code 3 on any unresolved conflict, including a future/bogus manifest
  `base_revision`.

## Required hosted checks

The required checks are:

1. `bats test suite` — complete `bats tests/` coverage.
2. `shell and static checks` — Bash syntax, Python compilation, ShellCheck, and
   whitespace/error checks.
3. `security and recovery gates` — focused path, symlink, permission,
   redaction, and upgrade-recovery regression tests plus gitleaks.
4. GitGuardian — hosted secret scanning for the repository and pull request.

If an upgrade is interrupted by a failed write, permission error, process exit,
or disk-full condition, the operator must preserve the failure output, inspect
the generated summary and backup state, and use the documented repair or
rollback path. A rerun is acceptable only after the interrupted state is
resolved and the result is idempotent. Do not delete backups or manifests as a
shortcut around a conflict.

Before opening a release PR, run the focused Bats file locally and review the
complete staged diff. Hosted CI and GitGuardian, not a partial local run, are
the authoritative release gates.
