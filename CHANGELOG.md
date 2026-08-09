# Changelog

All notable changes to The Rig are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

---

## [1.27.0] — 2026-08-09

### Added

- `/handoff-checklist`: new consent-gated wrap-and-handoff command for large
  or costly sessions. The prompt-submit hook only suggests handoff after the
  session-size benchmark is crossed; the checklist itself still requires
  explicit user agreement before any wrap/checklist work starts (#510).
- `templates/project/docs/INDEX.md`: new canonical project docs index
  convention. Feature-doc commands now maintain the index, `CLAUDE.md`
  documents project doc categories, and `README.md` points to the canonical
  index instead of duplicating a hand-written docs list (#512).

### Changed

- Contextual Rig tips are now relayed with an explicit "say exactly" hook
  instruction, visually labeled as `Rig tip`, expanded with a project-specific
  docs-index category, and made eligible again after an expiry window instead
  of being once-per-project forever (#511).
- CI Bats sharding now uses a weighted dynamic matrix planned from measured
  per-file timings instead of static round-robin assignment (#507).
- Two manually reviewed installer test clusters now share one bootstrap
  fixture per file, avoiding redundant installer setup while preserving the
  same behavior checks (#508).
- Bats assertions now avoid bash 3.2 traps from bare `[[ ... ]]` and
  single-line `! command` assertions; a scanner prevents regressions (#502).

### Fixed

- `copy_file()` now applies its symlink/conflict guard across strategies, not
  only `--strategy upgrade`, covering the installer's highest-traffic write
  path under fresh `merge` installs as well (#501).
- Upgrade planning now heals pre-#498 raw-template manifest hashes for
  `[BASE_BRANCH]`-substituted files when the on-disk content still matches the
  rendered current template, avoiding permanent false "customized"
  classifications (#514).
- Project template parity coverage now audits the full installed template tree,
  catching guarded-convergence artifact-list gaps such as missing
  `subagent-start.sh` coverage (#515).
- `/rig-help` now documents the actual shipped shell-command deny patterns and
  no longer claims SQL statement patterns are present in `settings.json`
  (#513).

---

## [1.26.2] — 2026-08-09

### Fixed

- `upgrade_prepare_directory()` (guards the global `~/.claude` root against a
  symlinked destination) was gated to `--strategy upgrade` only, silently
  no-oping under `merge` (the fresh-install default) — a symlinked
  `~/.claude` was followed with no refusal (#489).
- `upgrade_manifest_mutation_allowed()`, called on nearly every file write,
  had the same strategy-gating bug — a symlinked `.rig-manifest` was silently
  replaced under `merge` with no refusal (#490).
- The `CLAUDE.md` backup regression test asserted a marker string that
  couldn't distinguish a pristine backup from a clobbered intermediate one;
  strengthened to assert placeholder preservation directly (#491).
- `guard_destination_before_write()` couldn't distinguish a same-run creation
  from genuine pre-existing state, causing a spurious backup when
  re-migrating two `.claude/settings.json` call sites. Added a run-scoped
  `_RUN_WRITTEN_DESTINATIONS` tracker (#493).
- `_subst_base_branch()` ran after the manifest hash was already recorded, so
  every `[BASE_BRANCH]`-substituted file (`ship.md`, `post-merge.md`,
  `SHIP_WORKFLOW.md`, `POST_MERGE_WORKFLOW.md`, `CLAUDE.md`) had a stale
  manifest hash immediately after install — including a third `CLAUDE.md`
  mutation site (the external/stealth `@.rig/` import-path rewrite) found by
  a follow-up `/rig-surface-review` (#498).
- `upgrade_manifest_mutation_allowed()`'s conflict warning named whichever
  file happened to trigger a manifest write, not the actual conflicting
  destination — a single symlinked `.rig-manifest` produced misleading
  warnings blaming unrelated files each run (#503).
- `bin/rig worktree bootstrap` recursed into its own output when a linked
  worktree lived under `.claude/worktrees/` (this repo's own convention),
  consuming up to ~1.2GB before a filesystem path-length limit aborted it.
  Excluded `worktrees` from every directory copy in `worktree_bootstrap()`
  (#500).

### Changed

- CI's bats suite now runs sharded across an 8-job dynamic matrix
  (round-robin over `tests/*.bats`), cutting wall-clock from 45-48 minutes to
  ~8 minutes. `test_install.bats` (259 tests) was split into 5 files along
  its own existing section boundaries; a new `test-shard-coverage` job
  guards against shard/matrix drift (#505).

---

## [1.26.1] — 2026-08-08

### Fixed

- `/rig-upgrade` Phase 1e ("Check for user-modified Rig-owned files")
  resolved every manifest path as `$REPO/$rel_path`, so `.rig/`-prefixed
  entries in stealth/external tracking pointed at a path that never
  exists — silently missing user-modified files that needed review during
  an upgrade. The same bug was also present in Phase 2b-classic's diff and
  manifest-hash commands, fixed alongside it (#494).
- `install.sh`'s stealth git-hook installer treated a missing manifest
  baseline as automatic customization, with no fallback comparison against
  the incoming hook content — unlike every other Rig-owned file's upgrade
  handling. A hook installed before manifest tracking existed (or whose
  entry was lost) that still matched the current template was permanently
  misreported as needing manual review (#495).

Both found via a cold, zero-context subagent test of `/rig-upgrade` against
a real stealth-mode project, immediately after cutting v1.26.0.

---

## [1.26.0] — 2026-08-08

### Added

- `templates/global/CLAUDE.md`: new Working style bullet — when the agent
  notices the user repeating an instruction or preference for at least the
  second time, it proactively offers to codify it as a command, skill, or
  CLAUDE.md/rules bullet, rather than only complying again silently.
- A full pre-flight snapshot of a project's entire Rig/Claude/Codex
  footprint (including `.git/hooks/`) is now taken before any write in an
  `upgrade`/`agent-upgrade` strategy run, independent of and prior to the
  existing per-file backup mechanism. Stored under
  `.rig-backup/preflight-snapshots/` (tracked installs) or the external
  `.rig/`'s own `preflight-snapshots/` (stealth/external), with 5-snapshot
  retention (#472).
- `bin/rig doctor` gained 2 new post-upgrade validation checks
  (`upgrade_pattern_blanked_file`, `upgrade_pattern_symlink_replaced`)
  that diff the new pre-flight snapshot against current state for the 2
  historical bug patterns from `docs/lessons-learned.md` that are
  genuinely expressible as a before/after file diff (#473).

### Fixed

- `agent-plan`/`agent-upgrade` no longer leak CHANGELOG "BREAKING" bullets
  onto stdout, which broke the documented single-JSON-document contract
  whenever the target's installed version had a BREAKING changelog entry
  ahead of it (#475).
- `agent-plan`/`agent-upgrade` can no longer hang on a blocking interactive
  read. Fixed for the originally-reported branch-drift check, plus two
  more previously-undiscovered hangs of the identical class found via
  live TTY testing (a `--project-name` prompt and the `.rig/`
  tracking-mode menu) (#476).
- The notification-helper (`~/.claude/bin/rig-notify`, global
  `settings.json`) and Codex-config (`.codex/config.toml`) writes now get
  the same symlink-refusal/backup-before-write guard under every
  strategy, not just `--strategy upgrade` — matching the precedent set by
  the `.git/hooks/*` fix (#477).
- CHANGELOG "BREAKING" bullets spanning multiple lines were truncated to
  just their first line when printed during `--strategy upgrade`; indented
  continuation lines now print in full (#481).
- A duplicated `--strategy` flag (e.g. `--strategy agent-plan --strategy
  merge`) could silently suppress the installer-behind-remote branch-drift
  warning even when the run actually resolved to a normal, human-capable
  strategy — the early lookahead used seen-anywhere semantics instead of
  matching the real flag parser's last-wins behavior (#483).
- Extended the symlink-refusal/backup-before-write guard above to 7 more
  direct-writer destinations under every strategy, not just `--strategy
  upgrade`: `.rig/VERSION`, `.rigpath`, global and project
  `install-targets.json`, and CLAUDE.md's placeholder substitutions (#482).
  Three narrow gaps of the same class remain and are tracked as follow-ups,
  not fixed in this release: the global `~/.claude` root directory and the
  manifest bookkeeping file still lack the guard under non-upgrade
  strategies (#489, #490), and CLAUDE.md's backup can capture an
  intermediate state rather than the pristine original when more than one
  write touches it in the same run (#491).

---

## [1.25.0] — 2026-08-07

v1.24.0 shipped destructive regressions because the work leading up to it
was reviewed reactively — each fix checked only against the bug it claimed
to close, never against the full surface of what the installer does. This
release is a retroactive defensive audit of every PR merged since v1.23.0,
plus two structural gaps found along the way: an unconditional
backup-before-write invariant, and a new dev-only fresh-eyes review process
(`/rig-surface-review`) that caught a live data-loss bug in its first real
run.

### Fixed

- `bin/rig doctor`'s `manifest_mode_hash` and `stale_manifest_entries` gates
  resolved every manifest path against the project root unconditionally,
  false-failing on every stealth/external install — `.rig/`-prefixed
  entries actually live at `RIG_DIR` (via `.rigpath`) in stealth mode, not
  `root/.rig`. Added a `resolve_artifact(rel)` helper mirroring
  `install.sh`'s own existing redirect logic. [#468]
- Backup-before-overwrite had two live gaps of the same shape as the
  historical bug described below: the `interactive` strategy's overwrite
  confirmation never called `backup_file` at all, and the `merge`
  strategy's settings.json path gated its backup call on a condition
  (`$COLLISION_STRATEGY == upgrade`) that can never be true inside the
  `merge)` branch, so it silently never fired. [#470]
- `rig doctor`'s `manifest_mode_hash` no longer vacuously passes when the
  manifest has entries but none are Rig-owned. [#450]
- Global `CLAUDE.md`/`skills/*` manifest entries get correct `provider`
  metadata instead of inheriting the layer's agent selection. [#448]
- A symlinked git hook destination is refused, never silently destroys its
  target — and unlike the original fix, this protection now applies under
  every install strategy, not just `--strategy upgrade`. The default
  `merge` strategy (every fresh install) was still silently vulnerable;
  found by `/rig-surface-review`'s first real end-to-end run and confirmed
  via direct reproduction against a live checkout. [#451]
- `agent-plan` detects `.rigpath` conflicts instead of silently missing
  them. [#460]
- `agent-plan` no longer writes `.codex/config.toml` — a dry-run contract
  violation. [#446]
- `agent-plan`/`agent-upgrade` no longer leak narrative text — including
  preflight banners and gitleaks-missing remediation text — before their
  JSON output, restoring the documented "exactly one JSON document on
  stdout" contract. [#446]
- Stealth audit stops misclassifying a user's own file as a launcher leak.
  [#449]
- Frontmatter convergence merge no longer silently drops user comments on
  every successful merge. [#452]
- `upgrade_prepare_mutation()` journals first-ever file/hook creation, and
  no backup transaction is ever silently orphaned across the global/project
  layer boundary. [#470]

### Added

- New advisory `template_placeholder_content` doctor gate: flags when
  `CLAUDE.md`/`PROJECT_BRIEF.md` still shows the raw template's
  core-content placeholder. Deliberately worded as uncertain — it cannot
  distinguish "never filled in" from "reset by a historical bug" from disk
  state alone, especially on stealth installs where these files are
  git-excluded and there's no diff to catch it. [#468]
- `_upgrade_write()`: a single choke-point function that every collision-
  path write now goes through, making backup-before-overwrite a structural
  invariant instead of a per-branch responsibility. [#470]
- `guard_destination_before_write()`: extracted the symlink-refusal/backup
  logic into a strategy-agnostic helper, so a caller that needs this
  protection under every strategy (not just `upgrade`) can use it directly
  instead of the upgrade-only `upgrade_prepare_mutation()` wrapper. [#451]

### Documentation

- `docs/lessons-learned.md` #14: a months-old, already-fixed installer bug
  (v1.10.0 → v1.10.1) had silently reset `CLAUDE.md`/`PROJECT_BRIEF.md` to
  raw template content on several real projects, undetected for months on
  stealth installs where git shows no diff. Recovered on all affected
  projects; incident and recovery method documented.
- `docs/decisions.md` #19: backup-before-write as a structural invariant,
  not a per-branch responsibility.

### Known gaps (tracked, not blocking)

The same reachability class that hid the git-hook symlink bug above (a
narrow flag/strategy combination that no existing test exercised) surfaced
in two more places during review. Neither is introduced by this release —
both are pre-existing, narrower in reach, and tracked for a fast follow:

- `agent-plan`/`agent-upgrade` can still leak CHANGELOG "BREAKING" bullets
  onto stdout when upgrading a project whose installed version has an
  intervening breaking entry. [#475]
- The installer's own branch-drift check runs before `AGENT_MODE` is set,
  so it can print unguarded output — or, on a TTY, block on an interactive
  read — during an agent-driven run. [#476]
- The notification-helper and Codex-config writes have the same
  strategy-only guard gap the git-hook fix above closes, reachable via
  `--notifications` or `--project-agent codex` under the default `merge`
  strategy. [#477]

---

## [1.24.0] — 2026-08-05

### Added
- Agent-driven upgrade contract: `install.sh --strategy agent-plan`
  (read-only JSON preview, zero writes) and `--strategy agent-upgrade`
  (applies safe convergence, emits a JSON result, exits `3` on any
  unresolved conflict).
- Three-way and structure-aware convergence engine for customized JSON,
  TOML, and frontmatter-Markdown files under `agent-upgrade`.
- Manifest provenance metadata (`base_revision`/`generator`/`provider`
  fields) with a standalone validator, including a future/bogus
  `base_revision` gate — an entry claiming a revision newer than the
  running installer is refused, never silently trusted.
- `bin/rig doctor` gained five postflight gates: `manifest_provenance`,
  `stealth_status`, `manifest_mode_hash`, `stale_manifest_entries`,
  `idempotence`.
- `/rig-upgrade` now wires its Phase 2 to the agent-driven orchestrator via
  a new `--mode=agent` (default) / `--mode=classic` flag, with a Phase 3d
  `bin/rig doctor` postflight check.
- Stealth artifact audit/repair tooling (`installer/audit-stealth.py`,
  `installer/repair-stealth.py`) for classifying and safely repairing
  leaked Rig artifacts in stealth-tracked projects.

### Changed
- Stealth-mode git exclusion now covers every generated launcher sibling
  under `bin/`, not just `bin/rig`.
- Direct-writer mutations (`.rigpath`, `.rig/VERSION`, target-state
  metadata, `.codex/config.toml`, `.claude/settings.json` merges) are now
  journaled and recoverable through an interrupted upgrade.
- Stale-manifest detection now covers all four tracking layouts
  (repo/local/external/stealth) and reports missing/wrong-type/
  dangling-symlink/unexpected-symlink as four disjoint categories — only
  missing entries are ever auto-repaired.
- Stealth `.git/hooks/` writes are now manifest-tracked and backed up
  before an ordinary-mode overwrite, and refused (not silently
  overwritten) under `agent-upgrade` when customized.

### Fixed
- Three bugs that affected *ordinary* (non-agent) upgrade behavior, found
  and fixed during this release's own review process: the global-layer
  stale-manifest check resolved paths against the wrong root and produced
  false-positive missing reports; `.claude/settings.json` merges had no
  backup/transaction coverage; the stealth-exclude dedup check used a
  substring match that could silently drop `bin/rig` from the exclude list
  once a sibling launcher was written first.
- `bin/rig session resolve` restored: the native-identity resolver's
  ambient fallback now checks the host-injected `CLAUDE_CODE_SESSION_ID`
  before falling back to a PID-sentinel scheme that only worked one
  process hop from the session-start hook.
- `agent-plan` now detects stealth `.git/hooks/` customization conflicts —
  it previously skipped that entire detection path under dry-run, so a
  clean plan could be followed by an unpredicted `agent-upgrade` refusal.

---

## [1.23.0] — 2026-08-01

### Added
- Claude Code and Codex coexistence contracts, provider adapters, generated
  Codex skills, and native session identity recovery.
- Connector preflight contracts, hosted security/recovery gates, and release
  verification guidance.

### Changed
- Upgrade handling now records artifact ownership and metadata, preserves
  customizations, reports stale artifacts, supports safe legacy cleanup, and
  converges moved project roots and provider layouts.
- Upgrade writes reject symlink, dangling-link, wrong-type, and symlinked
  parent destinations without following or silently overwriting them.

### Security
- Session-file mutations, upgrade destinations, recovery journals, manifests,
  backups, and generated provider surfaces receive explicit path and privacy
  confinement checks.

### Fixed
- Installed Claude/Codex artifacts, generated adapters, external `.rig`
  mirrors, and repeated upgrade paths now have explicit parity and matrix
  coverage.

## [1.22.0] — 2026-07-19

### Fixed
- **`[#N]` auto-close clarification** (`templates/project/.rig/rules/git-conventions.md`): added explicit callout that `[#N]` in the commit subject is a reference only — GitHub auto-close requires `Closes #N`, `Fixes #N`, or `Resolves #N` in the PR body or commit body. The `/ship` PR template already includes `Closes #N`; the rule file now explains why. Closes #335.
- **Session-end marker format in `/wrap` Marker prune step** (`templates/project/.claude/commands/wrap.md`): documentation showed `<!-- session-end YYYY-MM-DD HH:MM -->` but `stop.sh` (v1.21.0+) writes `<!-- session-end YYYY-MM-DD HH:MM sid:UUID -->`. Stale format caused agents to emit markers without the UUID, breaking `/wrap` session attribution. Closes #336.
- **ERRORS.md trim stub direction ambiguity** (`templates/project/.claude/commands/wrap.md`): added `— NEW ENTRIES GO ABOVE THIS LINE` anchor to the archived stub format and explicit prose stating ERRORS.md is always newest-first. Prevents agents from appending new entries below the stub (which inverts sort order and causes the next trim to archive wrong entries). Closes #337.
- **`commit-msg` bypass hint for maintenance commits** (`templates/project/.husky/commit-msg`): the GitHub issue-reference error now shows both options — `# no-issue` body trailer (per-commit, preferred) and `SKIP_COMMIT_VALIDATION=1` (full bypass). Previously only the full bypass was shown in the error output, despite `# no-issue` being documented in the header comment. Closes #338.
- **`git add` inside pre-commit hook fails on Git 2.39+** (`templates/project/.rig/processes/UPGRADE_WORKFLOW.md`): added a "Known gotchas when extending hooks" section documenting the index-lock conflict and the `git update-index --add` workaround. The `pre-commit.sh` template already carries this comment (v1.21.0); this adds process-level coverage for users extending hooks. Closes #339.

---

## [1.21.0] — 2026-07-07

### Added
- **UUID-based session identity system** (`templates/project/.claude/hooks/stop.sh`, `session-start.sh`, `wrap.md`, `post-merge.md`): each session gets a UUID written to `/tmp/.rig-session-$PPID.uuid` at start; `stop.sh` annotates PROGRESS.md markers with `sid:UUID`; `pre-compact.sh` writes the UUID into the compact checkpoint; `/wrap` uses the anchor for session naming. Closes #315.
- **Permission scan opt-in in `/wrap`** (`templates/project/.claude/commands/wrap.md`): after transcript pruning, `/wrap` can scan the last 30 days of JSONL transcripts for Bash commands seen ≥3 times and append them to `permissions.allow`. Activate via `.fewer-prompts-enabled` sentinel. Closes #316.
- **Feature discovery tips system** (`templates/project/.claude/hooks/session-start.sh`): `show_tip()` + `collect_tips()` fire four one-time contextual tips during startup — session-name, fewer-prompts, task-tracking, and sprint. Global opt-out via `.rig-tips-disabled`. Closes #317.
- **`permissions.deny` baseline in `settings.json`** (`templates/project/.claude/settings.json`, `install.sh`): fresh installs include 3 deny patterns (`rm -rf *`, `git push --force*`, `git push -f*`); `merge_settings_json` deduplicates deny entries on upgrade (mirrors existing allow logic, with `or []` null guard). Closes #318.
- **`/code-review` command** (`templates/project/.claude/commands/code-review.md`): reads `test-command:`, `lint-command:`, `base-branch:`, `testing:`, `staging-url:`, and `prod-url:` from CLAUDE.md; analyses diff by category (logic, security, coverage, style); produces a LGTM/HOLD report; `--fix` mode applies suggestions one at a time. Commented-field false positive fixed (grep filters `#`-prefixed lines). CLAUDE.md template gains 5 optional commented fields. Closes #319.

### Changed
- **`stop.sh` now handles both Stop and SessionEnd events** (`templates/project/.claude/hooks/stop.sh`): dispatches on the `source` field from JSON stdin — empty source for per-turn Stop, `logout`/`prompt_input_exit`/`clear`/`resume` for SessionEnd. `session-end.sh` is deleted; upgrade path strips stale hook entries from `settings.json` and removes the file from disk. Closes #321.
- **`.rig/VERSION` is now written dynamically** (`install.sh`): removed static `templates/project/.rig/VERSION` — the installer writes `$INSTALLER_VERSION` to `.rig/VERSION` at install/upgrade time. Eliminates the two-file version bump requirement. `mkdir -p` safety added to the write block. Closes #322.

### Fixed
- **Compact hook JSON validation failure** (`templates/project/.claude/hooks/pre-compact.sh`, `post-compact.sh`): both hooks were emitting `hookSpecificOutput` with `hookEventName: "PreCompact"/"PostCompact"` — event names not in the Claude Code schema. Every compaction silently dropped hook output. Fix: replace `hookSpecificOutput` with the top-level `systemMessage` field, which is valid for all hook events. `pre-compact.sh` now emits the full checkpoint file (not just a summary line), providing more context during compaction. Closes #333.
- **Temp file cleanup on session start** (`templates/project/.claude/hooks/session-start.sh`): prunes `.compact-checkpoint-*.md` files older than 1 day on startup to prevent accumulation. Closes #320.
- **Transcript pruning opt-in in `/wrap`** (`templates/project/.claude/commands/wrap.md`): JSONL transcript pruning is now opt-in via `transcript-retention-days:` in CLAUDE.md; CLAUDE.md template adds the field (commented out by default). Closes #320.

---

## [1.20.0] — 2026-06-09

### Added
- **Auto-approval of `Edit`/`Write` to `$RIG_DIR` in `permission-request.sh`** (`templates/project/.claude/hooks/permission-request.sh`): the hook now resolves `$RIG_DIR` at runtime (`.rigpath` for stealth mode, `$REPO/.rig` fallback) and auto-approves any `Edit`, `Write`, or `NotebookEdit` call targeting a path under it. Eliminates repeated permission prompts for writes to Rig's own memory, tasks, and docs. Opt-out: `touch $RIG_DIR/memory/.rig-strict-permissions`. Closes #312.
- **`/tmp/` write patterns in baseline `settings.json`** (`templates/project/.claude/settings.json`): `Write(/tmp/*.md)` and `Write(/tmp/*.txt)` added to the default `permissions.allow` list so agents can use temp files without approval.

---

## [1.19.0] — 2026-06-08

### Added
- **`/rig-status` command** (`templates/project/.claude/commands/rig-status.md`): installation health check — verifies hook wiring, memory files, settings.json entries, and pending flags in one pass. Run any time to confirm the project layer is intact, especially after re-cloning on a new machine. Closes #296.
- **Stale-version offer in `install.sh`** (`install.sh`): when the installer source is behind the tracking remote, an interactive 3-option prompt now offers to pull-and-rerun (recommended), continue with the stale version, or exit. In non-interactive mode, behavior is unchanged (warn and continue). The re-run uses `exec` to pass all original flags through. Closes #299.
- **`/fewer-permission-prompts` baseline seeding** (`install.sh`, `templates/project/.claude/settings.json`): fresh installs now seed 5 `permissions.allow` entries for common read-only git patterns (`git log`, `git diff`, `git show`, `git status`, `git branch`) that would otherwise prompt every session. Closes #294.
- **One-time nudge for `/fewer-permission-prompts`** (`templates/project/.claude/hooks/prompt-submit.sh`): after a few sessions, `prompt-submit.sh` surfaces a one-time suggestion to run `/fewer-permission-prompts` to expand the allowlist. Fires at most once per project (`.permission-nudge-offered` sentinel). Closes #294.
- **PR description freshness check in `/wrap` and `/ship`** (`templates/project/.claude/commands/wrap.md`, `ship.md`): before ending a session or committing, checks whether the open PR description is stale relative to new commits. Skips housekeeping commit types. Closes #293.
- **Upgrade commit strategy guidance** (`templates/project/.rig/processes/UPGRADE_WORKFLOW.md`, `templates/project/.claude/commands/rig-upgrade.md`, `templates/project/CLAUDE.md`): Step 7 in `UPGRADE_WORKFLOW.md` and Phase 5a in `rig-upgrade.md` now recommend branch+PR when 4+ files change, direct-push for 1–3 files. `CLAUDE.md` `housekeeping:` table clarifies upgrade commits are not covered by the direct-push convention. Closes #301.

### Fixed
- **Stale in-repo `.rig/` cleanup** (`install.sh`): when a stealth install detects a residual in-repo `.rig/` directory from a prior non-stealth install, the default is now auto-remove (was: skip). In non-interactive mode the removal is automatic; interactive mode defaults to `y`. Closes #297.
- **`/wrap` and `/post-merge` session report** (`templates/project/.claude/commands/wrap.md`, `post-merge.md`): standardized report format, auto-executes housekeeping steps without confirmation gates, and removes stale prompts ("Trim now?", "Did anything unexpected happen?"). Closes #292.
- **`/ship` Step 9 and `/wrap` PR freshness**: uses `chore(memory)` skip filter so housekeeping commits don't falsely trigger a "description is stale" warning. Closes #293.
- **`--project-only` non-interactive mode** (`install.sh`): `--project-only` without `--strategy` no longer blocks on the intent menu in non-interactive mode — defaults to upgrade intent. Closes #295.

### Changed
- **`/wrap` and `/post-merge` report cadence** (`templates/project/.claude/commands/wrap.md`, `post-merge.md`): session summary is now produced as a single Wrap report / Post-merge report before housekeeping steps execute. No mid-flow confirmation gates. Closes #292.
- **Stale `.rig/` removal default changed to `y`** (`install.sh`): in-repo `.rig/` cleanup during stealth migration now auto-removes in non-interactive mode (changed from default-no to default-yes). Closes #297.

---

## [1.18.1] — 2026-05-26

### Fixed
- **Upgrade tracking mode auto-detect** (`install.sh`): `--strategy upgrade` without `--tracking` now infers the existing mode from git state when `.rigpath` is absent — git-committed `.rig/` → repo; `.rig/` in `.git/info/exclude` or `.gitignore` → local. Previously fell through to the interactive prompt which defaulted to stealth, silently migrating repo/local installs. 3 new bats tests. Closes #262.

---

## [1.18.0] — 2026-05-26

### Added
- **`session-start.sh` hook** (`templates/project/.claude/hooks/session-start.sh`, `SessionStart`): injects `CONTEXT_SNAPSHOT.md` content and any pending housekeeping flag warnings (`.wrap-needed`, `.post-merge-pending`) into the conversation as `additionalContext` at the very start of each session — before the first user turn. Eliminates the need for the agent to manually read these files. Closes #238.
- **`prompt-submit.sh` hook** (`templates/project/.claude/hooks/prompt-submit.sh`, `UserPromptSubmit`): re-checks `.wrap-needed` and `.post-merge-pending` flags on every user prompt and re-injects warnings when they are present. Ensures warnings persist across multi-turn sessions. Closes #241.
- **`permission-request.sh` hook** (`templates/project/.claude/hooks/permission-request.sh`, `PermissionRequest`): auto-approves safe, read-only tool patterns (Read, Bash read-only commands, non-destructive Grep/Find) so they never prompt. Reduces permission-prompt noise for routine operations. Closes #239.
- **`pre-compact.sh` hook** (`templates/project/.claude/hooks/pre-compact.sh`, `PreCompact`): writes a `.compact-checkpoint.md` file before context compaction, capturing current branch, last commit, active task, and session progress markers. Outputs a `compactionSummary` JSON field so Claude receives orientation context immediately after compaction. Closes #232.
- **`post-compact.sh` hook** (`templates/project/.claude/hooks/post-compact.sh`, `PostCompact`): reads `.compact-checkpoint.md` back and injects its content as `additionalContext` after compaction completes, restoring the working context that would otherwise be lost. Closes #232.
- **`session-end.sh` hook** (`templates/project/.claude/hooks/session-end.sh`, `SessionEnd`): handles true session termination (distinct from `Stop`, which fires after every agent turn). Dispatches by source signal: on logout/clear, writes `.wrap-needed` and a minimal auto-checkpoint; on resume, clears the `.wrap-needed` flag. Owns the wrap-needed logic that was previously in `stop.sh`. Closes #240.
- **`subagent-start.sh` hook** (`templates/project/.claude/hooks/subagent-start.sh`, `SubagentStart`): injects project name, current branch, active task slug, and key conventions into spawned subagents so they share the same working context as the parent session. Closes #244.
- **`/ship` Step 4.5 — code-reviewer offer** (`templates/project/.claude/commands/ship.md`): after the checklist gate, `/ship` optionally invokes the `code-reviewer` agent for a lightweight pre-commit correctness scan. Accepts yes/no/skip; non-blocking. Closes #228, #230.
- **`/ship` Step 4.8 — docs/memory freshness gate** (`templates/project/.claude/commands/ship.md`): before commit, checks whether any feature docs or memory files that overlap with the PR's touched files are stale. Surfaces stale docs and waits for user decision (update now / skip). Closes #230.
- **`--feature-docs` installer flag** (`install.sh`): gates `/doc-feature`, `/doc-list`, `/feature-context`, `/refresh-feature-doc`, and `docs/features/` installation behind an explicit opt-in flag. Default installs are leaner; projects that want feature-knowledge tooling pass `--feature-docs` to include it. Closes #250.
- **`code-reviewer.md` agent template** (`templates/project/.claude/agents/code-reviewer.md`): reusable sub-agent for lightweight pre-commit code review. Invoked optionally by `/ship` Step 4.5; can also be triggered directly. Checks for correctness issues, logic errors, and missed edge cases in staged changes. Closes #228.
- **Breaking-change gate in `install.sh --strategy upgrade`** (`install.sh`): new `_show_breaking_changes()` function uses `awk` to extract `### Changed — BREAKING` bullets from all CHANGELOG sections newer than the installed version. Fires before any files are touched; prompts the user to confirm before proceeding. Silent in CI/non-interactive mode (default-yes). Test injection via `_RIG_TEST_CHANGELOG`. Closes #258.
- **Breaking-change gate in `/rig-upgrade`** (`templates/project/.claude/commands/rig-upgrade.md`): Phase 1b added between pull (1a) and tracking-mode detection (now 1c). After `git pull`, reads `CHANGELOG.md` for breaking changes between installed and incoming version. Requires user to type **go** to proceed or **cancel** to abort before Phase 2 writes any files. Closes #258.

### Changed — BREAKING
- **Default install tracking mode changed to stealth** (`install.sh`): the interactive
  prompt now defaults to option 4 (stealth) instead of option 1 (in-repo). All Rig
  files are stored in `~/.rig/projects/<name>/` by default — no `.rig/` is committed
  to the project repo. Users who prefer in-repo tracking must choose option 1 explicitly
  or pass `--tracking repo`. This affects all fresh installs where no `--tracking` flag
  is provided. Closes #233.

### Changed
- **`stop.sh` simplified** (`templates/project/.claude/hooks/stop.sh`): stripped to date-update + session-end marker only. The `.wrap-needed` sentinel logic moved to `session-end.sh`, which fires on true termination events rather than after every agent turn. The `Stop` hook still fires after every response — it now only updates the `Last updated:` timestamp and appends a `<!-- session-end -->` boundary marker to `PROGRESS.md`. Closes #240.
- **`housekeeping: direct-push` type guard** (`templates/project/.claude/hooks/pre-tool.sh`): `direct-push` now blocks commit types that indicate code changes (`feat`, `fix`, `refactor`, `test`, `perf`, `devops`, `style`) even when `direct-push` is set. Only `chore` and `docs` commit types can go directly to the base branch. `feat`, `fix`, and all other code-change types must go through a PR regardless of the housekeeping setting. Closes #221.
- **Worktree redirect in `pre-tool.sh`** (`templates/project/.claude/hooks/pre-tool.sh`): `PreToolUse` now intercepts `Write`, `Edit`, and `NotebookEdit` calls targeting `.claude/worktrees/` paths and transparently redirects them to the main-repo equivalent path via `updatedToolInput`. Hard rule #12 (never edit inside a worktree) is now mechanically enforced rather than relying on the agent. Closes #242.
- **`/pre-release-review` scope clarified** (`templates/project/.claude/commands/pre-release-review.md`, `rig-help.md`): opening paragraph now explicitly states the command is for projects with a formal release cycle (versioned libraries, shipped products, public APIs). Not needed for scripts, CLIs, or internal tools. Marked `(release-cycle projects)` in `/rig-help`. Closes #246.
- **`/kickoff` marked as one-shot** (`templates/project/.claude/commands/kickoff.md`, `rig-help.md`): header now states "Run once, at project creation." End-of-flow (Step 5) includes a suggestion to delete `.claude/commands/kickoff.md` after use. Marked `(new projects only)` in `/rig-help`. Closes #247.
- **`/rig-gaps` scoped to Rig contributors** (`templates/project/.claude/commands/rig-gaps.md`, `rig-help.md`): header now states the command is for users who contribute to or develop The Rig. Submit-step framing simplified: "Review logged gaps and decide which to act on. If you're contributing to The Rig, bring these to a Rig dev session." Marked `(Rig contributors)` in `/rig-help`. Closes #249.
- **`## Personal context` section inlined into global `CLAUDE.md`** (`templates/global/CLAUDE.md`): personal context prompts (name, role, expertise, preferences, goals) now live directly in `CLAUDE.md` as a `## Personal context` section. Closes #248.
- **`DOCS_DIR` resolution standard for stealth/external projects** (`templates/project/.claude/commands/`): stealth projects (`.rigpath` exists) resolve `DOCS_DIR` to `$RIG_DIR/docs`; in-repo projects use `$REPO/docs`. Applied consistently across `/doc-feature`, `/refresh-feature-doc`, `/feature-context`. Closes #250.

### Removed
- **`/new-feature` command** (`templates/project/.claude/commands/`): deprecated redirect to `/task`. Removed from template install. Closes #245.
- **`/rig-install` command** (`templates/project/.claude/commands/`): guided install wizard. Removed from template install — `/rig-upgrade` covers all upgrade scenarios; new installs use `install.sh` directly. Closes #245.
- **`PROFILE.md.example`** (`templates/global/`): personal context file removed from the global template. Content is now inlined in `templates/global/CLAUDE.md` as `## Personal context`. Closes #248.

---

## [1.17.0] — 2026-05-18

### Added
- **`/rig-upgrade --version` GitHub release check** (`templates/project/.claude/commands/rig-upgrade.md`): the `--version` flag now fetches the latest tagged release from `laudtetteh/the-rig` via the `gh` CLI and includes it in the version output. Warns if the installed version is behind the latest release. Gracefully omits the line if `gh` is unavailable or the network is unreachable. Updated README and `docs/how-it-works.md` to document the new output. Closes #222.

---

## [1.16.0] — 2026-05-18

### Added
- **`/run` operating mode prompt** (`templates/project/.claude/commands/run.md`): tasks without a `## Operating mode` block now trigger an inline three-setting wizard (autonomy / codebase knowledge / uncertainty handling). The answer is written back to the task file and skipped on all future runs for that task. Closes #185.
- **`/wrap` concurrent session guard** (`templates/project/.claude/commands/wrap.md`): a `.wrap-in-progress` sentinel blocks a second concurrent `/wrap` call from corrupting `CONTEXT_SNAPSHOT.md`. Sentinel deleted at final cleanup. Tighter session boundary detection for mid-session runs. Closes #186.
- **`/rig-upgrade --version` and `--scope` flags** (`templates/project/.claude/commands/rig-upgrade.md`): `--version` prints project + global installer versions with last-modified timestamps and warns if they differ. `--scope project|global|both` limits the upgrade surface without a full reinstall. Closes #187.
- **`/task` test intake + `/ship` pre-commit cleanup** (`templates/project/.claude/commands/task.md`, `ship.md`): `/task` intake adds question 5 ("Tests required?"); answer written to task file under `## Testing`. `/ship` Step 3.8 actively removes debug statements and runs the linter before the pre-commit checklist. Both commands detect PR updates vs. new PRs. Closes #189.
- **Main-branch commit guard** (`templates/project/.claude/hooks/pre-tool.sh`): blocks `git commit` directly to `main`/`master` unless `CLAUDE.md` sets `housekeeping: direct-push`. Prevents accidental direct commits in feature-branch projects. Closes #190.
- **Command routing table** in global `CLAUDE.md` template (`templates/global/.claude/CLAUDE.md`): maps user intent signals to the correct Rig command. Agent surfaces the command and asks for consent before routing — explicit confirmation required, silence is not enough. Closes #191.
- **`docs/INDEX.md` + `/doc-list` + `/rig-help` + `/status` commands**: `docs/INDEX.md` lists all docs with one-line descriptions. `/doc-list` reads it. `/rig-help` displays all slash commands grouped by workflow with signatures and descriptions. `/status` surfaces current branch, task, and session state. Closes #192.
- **`/rig-upgrade` result collection** (`templates/project/.claude/commands/rig-upgrade.md`): result accumulator arrays (`UPGRADED`, `CUSTOMIZED_ACCEPTED`, `CUSTOMIZED_KEPT`, `SKIPPED_BASE_BRANCH`, `FIXED`, `GLOBAL_UPDATED`, `GLOBAL_SKIPPED`) are populated during Phases 2–4 and read in the Phase 5 summary, replacing static placeholders with an accurate upgrade report. Closes #203.
- **`/pre-release-review` command** in two variants: `.claude/commands/pre-release-review.md` (Rig-specific — covers bats, upgrade path, `is_rig_owned`, `[BASE_BRANCH]` substitution); `templates/project/.claude/commands/pre-release-review.md` (generic, ships to all installed projects). Closes #212.
- 23 new bats tests: main-branch commit guard (3 tests, PR #205), behavior simulation for `/status`, `/wrap`, `/ship`, `/rig-upgrade` (16 tests, PR #207), structural linting across all 22 command files (4 tests, PR #208). Suite: 86 → 109 tests total.

### Fixed
- **`/recon` + `/doc-feature`** (`templates/project/.claude/commands/recon.md`, `doc-feature.md`): Step 0 now checks `docs/features/`, `DECISIONS.md`, `ERRORS.md`, and `PROGRESS.md` before sweeping external sources — surfaces existing knowledge first and asks whether a full sweep is still needed. Closes #188.
- **Command routing consent**: routing instruction tightened so the agent must surface the right command and ask for confirmation before acting; silence is not confirmation. Closes #191.
- **`pre-tool.sh` python3 fallback** (`templates/project/.claude/hooks/pre-tool.sh`): python3 absence silently disabled both the commit gate and write protection. Added `command -v python3` check with a `grep`-based fallback so both guards remain active on systems without python3. Closes #212.
- **`/rig-upgrade` ANSI-safe result parsing** (`templates/project/.claude/commands/rig-upgrade.md`): installer's `success()` prefixes output with ANSI color codes, causing the `Updated:*` prefix pattern to never match. Changed to substring match (`*"Updated: "*`). Closes #212.

### Changed
- **`/rig-help`** (`templates/project/.claude/commands/rig-help.md`): 4 missing commands added (`/post-merge`, `/session-name`, `/rig-install`, `/propose` alias); 3 incorrect descriptions corrected (`/run`, `/sprint`, `/recon`); 4 missing argument signatures added. Template synced. Closes #210.
- **`README.md`** and **`docs/how-it-works.md`**: command count updated 13 → 22; `/rig-install` added to command tables; `python3` added to requirements table; `## Release` section added for `/pre-release-review`. Closes #210, #212.
- **`docs/troubleshooting.md`**: item #8 added — "Commit to 'main' blocked by The Rig" — with fixes for both feature-branch projects (create a branch) and solo/housekeeping projects (`housekeeping: direct-push`). Closes #212.
- **Installer `.rigpath` auto-detection** (`install.sh`): `--strategy upgrade` without `--tracking` now detects an existing `.rigpath` and infers `stealth` or `external` mode automatically, preventing `.rig/` files from landing in the project directory instead of the external path. Stealth installs also now add `.rig/` to `.git/info/exclude` alongside `.rig-backup/`. 2 new bats tests (111 total). Closes #217.

---

## [1.15.0] — 2026-05-09

### Added
- **`/rig-gaps --submit`** (`templates/project/.claude/commands/rig-gaps.md`): opt-in GitHub issue creation. When `.rig/memory/.rig-contribute-enabled` sentinel exists and `gh` is authenticated, each unsubmitted gap entry is reviewed individually (yes / edit / skip / stop) and posted as a public issue to `laudtetteh/the-rig`. Submitted entries are marked with `[submitted: github:#N YYYY-MM-DD]` in `RIG_GAPS.md`. Closes #131.
- **`rig-gaps-push-target:` and contribute mode documentation** in `templates/project/CLAUDE.md`: documents the `rig-gaps-push-target:` field and the `.rig-contribute-enabled` opt-in sentinel with the `touch` command and privacy notice.

### Changed
- **`docs/how-it-works.md`**: command count updated 14 → 17; `/sprint`, `/feature-context` added to command tables; `/rig-gaps` entry updated to document `--push` and `--submit` flags; `commit-msg` section documents `# no-issue` bypass; `stop.sh` section documents auto-checkpoint; project settings table adds `rig-gaps-push-target:` field. Closes #182.
- **`docs/customizing.md`**: `rig-gaps-push-target:` added to project settings quick-reference block; new section documents the field and the `/rig-gaps --submit` contribute-mode opt-in. Closes #182.

---

## [1.14.0] — 2026-05-09

### Added
- **`/feature-context [name]`** (`templates/project/.claude/commands/feature-context.md`): loads an existing feature doc into context before starting work. Fuzzy matches on slug or title, shows entry points / business rules / gotchas, warns if the doc is >60 days old. Gracefully falls back to `/doc-feature` if no match is found. Closes #166.
- **`/sprint`** (`templates/project/.claude/commands/sprint.md`): conflict-aware sprint planner. Reads `## Files likely affected` from each task file, builds a conflict graph, groups tasks into conflict-free waves, and executes wave by wave with a review pause between waves. Supports targeted `/sprint [slug …]` and `--issues #N …` modes. Closes #174.
- **`## Batches` section** (`templates/project/.rig/tasks/backlog/TASK_example.md`): promoted from an HTML comment to a real optional section. `/run.md` Step 4 now fills in the `Commit` column after each commit in a multi-batch task. `NEW_TASK_WORKFLOW.md` Step 7 verifies batch hashes before moving to done. Closes #175.
- **`rig-gaps-push-target:` field** in `templates/project/CLAUDE.md`: when set, `/rig-gaps --push` appends unsubmitted gap entries directly to the target Rig repo's `RIG_GAPS.md` file, with dedup check and confirmation before append. Closes #168.
- **Installer branch drift warning** (`install.sh`): warns when the installer's own git repo is behind its remote tracking branch before proceeding. Silent if no remote or no network. `_RIG_DRIFT_DIR` env var allows test injection. Closes #172.
- **`stop.sh` auto-checkpoint** (`templates/project/.claude/hooks/stop.sh`): when `.wrap-needed` is written, also writes a minimal `CONTEXT_SNAPSHOT.md` checkpoint (current branch, last commit hash, active task file) so the next session has orientation data even if `/wrap` never ran. Closes #173.
- 5 new bats tests (86 total).

### Fixed
- **`/doc-feature` + `/refresh-feature-doc`** now resolve `$RIG_DIR` via `.rigpath`; stealth projects write feature docs to the external directory instead of into the repo. Closes #165.
- **`commit-msg` hook**: `# no-issue` body line bypasses the issue reference check for any tracker (GitHub, Linear, Trello, GUS). Useful for one-off chores with no ticket. Closes #170.
- **`pre-commit` hook**: header comment warns that `git add` inside hooks causes `index.lock` errors on Git 2.39+; use `git update-index --add` instead. `docs/troubleshooting.md` gains item #7 with the fix. Closes #171.

### Changed
- **`/post-merge`**: Step 5 added — diffs merged PR files against feature doc entry point paths and prompts `/refresh-feature-doc` for any overlap. Closes #167.
- **`/wrap`**: lighter feature doc freshness check added covering recent session commits. Closes #167.
- **`/rig-gaps`**: push mode (`--push`) added; appends unsubmitted entries to `rig-gaps-push-target:` path. Closes #168.
- **Tiered session naming** in `/session-name`, `/wrap`, `/post-merge`: ≤5 units listed explicitly; 6–15 grouped by type; 16+ condensed into a sprint summary line. Closes #169.
- **`NEW_TASK_WORKFLOW.md` Step 1b**: explicit branch creation gate added — no `Write`, `Edit`, or `Bash` tool calls that modify project files until the branch is created. Closes #176.
- **`/sprint` command** entries added to `README.md` command quick-reference.
- **`/feature-context`** entry added to `README.md` feature knowledge table.

---

## [1.13.0] — 2026-05-09

### Added
- `GLOBAL_MANIFEST_FILE` (`~/.claude/.rig-global-manifest`) tracks SHA256 of installed global files
- `_copy_global_file_upgrade()` — manifest-aware upgrade handler for global layer files
- Interactive intent 3 (Upgrade) now also syncs the global layer (`DO_GLOBAL=true`)
- Global upgrade: auto-extracts existing `PROFILE_PATH` from installed `~/.claude/CLAUDE.md` (no prompt)
- Global upgrade: `PROFILE.md` is never touched (personal data, always off-limits)
- 2 new bats tests for global upgrade behavior (75 total)
- **Multi-tracker issue enforcement** (`templates/project/CLAUDE.md`, `templates/project/.claude/commands/task.md`, `templates/project/.rig/processes/NEW_TASK_WORKFLOW.md`, `templates/project/.husky/commit-msg`): expanded issue-tracking support from GitHub-only to Linear, Trello, and GUS. `CLAUDE.md` now documents all five `issue-tracking:` values (`github`, `linear`, `trello`, `gus`, `none`) with per-tracker ref formats. Added `issue-creator:` field (`user` | `agent`) with `agent` only applying to GitHub. The `/task` intake wizard handles all tracker types in question 4. `NEW_TASK_WORKFLOW.md` Step 0 updated to document all trackers and their required ticket validation rules. `commit-msg` hook Step 3 now validates per-tracker ref format (`[#N]` for GitHub, `[TEAM-123]` for Linear, `[trello:ID]` for Trello, `[W-N]` for GUS, no check for `none`). 6 new bats tests (79 total). Closes #155.
- **`docs/agent-install.md`**: complete non-interactive installer reference for agent-driven installs — all eight install scenarios with exact flag combinations, tracking mode and strategy tables, and a post-install verification checklist. Primary guidance for any Claude agent helping a user install The Rig; readable from the repo without any prior setup. Also added a `/rig-install` slash command (`.claude/commands/rig-install.md`, local only — excluded from git by stealth mode) that wraps this doc into an interactive guided flow for users who already have The Rig running in this repo. Closes #159.

### Fixed
- `RIG_TRACKING` was unbound during `--global-only` runs, crashing `init_backup_dir` under `set -u`
- `mktemp /tmp/rig-global-claude-XXXXXX.md` used non-portable suffix (X's must be at end on macOS); replaced with bare `mktemp`
- `BACKUP_DIR` reset between global and project layer so each layer uses its correct base path

### Changed

- **Documentation updated for v1.13.0 state** (`README.md`, `docs/how-it-works.md`, `docs/customizing.md`, `docs/decisions.md`): commit-msg hook description now includes Conventional Commits validation and per-tracker issue ref enforcement; `/rig-upgrade` added to command lists; installer flags section in how-it-works documents `--tracking`, `--target`, `--strategy`; issue-tracking settings table expanded to all five values; `--rig-dir` → `--tracking external` corrected in customizing.md; three new decision entries (#11–#13) for `--tracking` flag decoupling, global upgrade manifest, and multi-tracker issue enforcement. Closes #160.

---

## [1.12.0] — 2026-05-07

### Added

- **Conventional Commits validation in `commit-msg` hook** (`templates/project/.husky/commit-msg`): after stripping auto-injected tool footers, the hook now validates that the commit subject matches the Conventional Commits format (`type(scope): description`). Valid types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`, `devops`, `style`. Merge, revert, fixup, and squash commits are exempted. `SKIP_COMMIT_VALIDATION=1` env var bypasses validation. Also requires a GitHub issue reference (`[#N]` or `(#N)`) when `issue-tracking: github` is set in `CLAUDE.md`. Closes #149.

- **Branch naming convention check in `post-tool.sh`** (`templates/project/.claude/hooks/post-tool.sh`): after any `git checkout -b` call, the hook now inspects the new branch name and warns if it doesn't match the `type/` prefix convention (`feat/`, `fix/`, `chore/`, etc.). Advisory only — does not block the checkout. Closes #149.

- **Proactive `.wrap-needed` on 2+ commits** (`templates/project/.claude/hooks/stop.sh`): `stop.sh` now writes `.wrap-needed` when 2 or more commits land in a session, even if auto-stubs have already been expanded. Ensures `/wrap` is prompted after productive sessions regardless of stub state. `RIG_SESSION_LOG` is now injectable via env var for test isolation. Closes #149.

- **Issue number validation in `NEW_TASK_WORKFLOW.md`**: the workflow now validates that a task file's `**GitHub issue**: #[N]` field is populated before Step 1 can proceed. Applies whether the task was opened via `/task`, picked from the backlog, or resumed from `active/`. Closes #149.

- **Pre-ship checklist gate in `SHIP_WORKFLOW.md` and global `CLAUDE.md`**: Step 2.5 of `SHIP_WORKFLOW.md` is now named "Checklist confirmation + pause for local testing" and requires explicit confirmation that the Step 1 checklist has been worked through before the commit prompt is presented. Hard Rule #11 in the global `CLAUDE.md` template updated to match. Closes #149.

- **Scope-gate fires before first tool call** (`templates/global/CLAUDE.md`): the freeform change-request gate now explicitly requires the agent to wait for a user response before invoking any `Write`, `Edit`, or `Bash` tool. Trigger-word list added for clarity. Closes #149.

### Fixed

- **Stealth/external upgrade writes `.rig-backup/` to the project root** (`install.sh`): `init_backup_dir()` was always creating `.rig-backup/<timestamp>/` in the target project regardless of tracking mode. In stealth and external mode, backups are now redirected to `$EXTERNAL_RIG_DIR/backups/<timestamp>/` — zero traces left in the project. Also added `.rig-backup/` to the stealth `.git/info/exclude` block as a safety net. Closes #148.

- **Upgrade docs showed wrong working directory** (`docs/customizing.md`): the upgrade snippet showed `./install.sh --project-only` run from the project directory — wrong. Corrected to the two-step form: `cd ~/tools/the-rig && ./install.sh --project-only --target <project-path> --strategy upgrade`. Backup location note updated to reflect stealth-mode path. Closes #148.

---

## [1.11.0] — 2026-05-07

### Added

- **`--tracking` flag** (`install.sh`): new `--tracking repo|local|external|stealth` flag sets tracking mode non-interactively. `--target` and `--tracking` are now orthogonal — `--target` sets the install path only and no longer suppresses the tracking prompt. For fully non-interactive stealth installs: `./install.sh --target <path> --tracking stealth`. `read || true` guards EOF on all tracking prompt `read` calls for CI use. Closes #142.

- **`--skip-git-hooks` flag** (`install.sh`): new flag for stealth mode that skips writing to `.git/hooks/` entirely. Useful when the target project manages hooks via Husky or another tool and the user wants to wire Rig hooks manually. Closes #141.

### Fixed

- **Stealth mode silently conflicts with existing Husky setup** (`install.sh`): when stealth mode is chosen for a project with a `.husky/` directory, the installer now warns that Rig hooks written to `.git/hooks/` may be overwritten if `npm install` or `prepare` re-runs `husky install`. Warning includes the `--skip-git-hooks` opt-out. Closes #141.

- **Self-install detector deletes committed source files** (`install.sh`): when `install.sh` is run with the target directory equal to the directory containing `install.sh` (i.e. inside The Rig's own repo), the cleanup prompt was firing and offering to delete `install.sh`, `templates/`, `docs/`, `CHANGELOG.md`, etc. — the actual project files. Fixed by checking `git ls-files --error-unmatch install.sh` before entering the cleanup block: if `install.sh` is a committed file in the repo, cleanup is silently skipped. Closes #143.

---

## [1.10.1] — 2026-05-06

### Fixed

- **Upgrade installer crash on projects missing manifest entries** (`install.sh`): `read_manifest_hash` used `grep | awk | head` — when grep found no match it exited 1, which propagated through `pipefail` and killed the installer under `set -euo pipefail`. All files not yet in the manifest (user-owned files on a first upgrade from pre-1.10.0) would crash the install. Fixed by appending `|| true` to suppress the grep no-match exit code.

- **Upgrade silently overwrote user-owned files** (`install.sh`): When a file had no manifest entry (i.e. was installed before manifest tracking was extended to all files in v1.10.0), `_copy_file_upgrade` treated it as "unmodified since install — safe to overwrite." This caused `CLAUDE.md`, `PROJECT_BRIEF.md`, and all `.rig/memory/*.md` files to be silently overwritten on upgrade. Fixed by splitting the empty-manifest case: Rig-owned files (hooks, commands, processes) are still auto-updated; user-owned files are skipped safely and their current hash is recorded so future upgrades can detect real customizations.

---

## [1.10.0] — 2026-05-06

### Added

- **Configurable project settings** (`templates/project/CLAUDE.md` `## Project settings` block): five fields now control Rig behavior per project without touching command files — `issue-tracking: github | none`, `secret-scanner: gitleaks | none`, `commit-cleanup: yes | no`, `base-branch:` (existing), `housekeeping:` (existing). Setting `issue-tracking: none` disables the GitHub issue gate across `/task`, `/ship`, `SHIP_WORKFLOW`, and `NEW_TASK_WORKFLOW`. Closes #134.

- **Branch confirmation based on autonomy level** (`ship.md` Step 3.5, `task.md`, `SHIP_WORKFLOW.md` Step 3c): before `git checkout -b`, Low/Medium autonomy confirms the base branch with the user; High autonomy reads `base-branch:` from `CLAUDE.md`, states it, and proceeds immediately. Closes #127.

- **Stale-main detection before branching** (`NEW_TASK_WORKFLOW.md` Step 1a, `SHIP_WORKFLOW.md` Step 3b, `ship.md` Step 3.5): `git fetch` + `rev-list` check before any new branch is created. If the base branch has advanced, Low/Medium prompts to rebase; High autonomy auto-rebases. Prevents the "working from outdated main" problem when multiple PRs are open simultaneously. Closes #128.

- **Mandatory post-batch audit** (`SHIP_WORKFLOW.md`, `ship.md`): after every group of related PRs, a checklist ensures tests pass, CLI help text is accurate, docs are updated, CHANGELOG has entries, inline comments are consistent, and CONTEXT_SNAPSHOT is current. Closes #129.

- **ERRORS.md archive breadcrumb** (`wrap.md`): after trimming entries to the archive, a compact stub comment is appended to the active file listing the archived topics/categories. Provides a grep-able index into the archive without loading it. Prevents archive blindness. Closes #136.

- **Check-before-log for ERRORS.md** (`wrap.md`): new explicit ERRORS.md logging step instructs the agent to search both the active file and `ERRORS_archive.md` before creating any new entry — update existing entries on recurrence rather than duplicating them. Prevents the same pitfall from being re-logged after a trim, which would hide that it is a *recurring* problem. Closes #136.

- **Context and token management documentation** (`docs/how-it-works.md`): new section documenting session-start baseline (~7K tokens from measured template sizes), the CONTEXT_SNAPSHOT gate, trim limit rationale, and the honest note that tool call accumulation (not Rig files) is the dominant cost driver.

- **Project settings documentation** (`docs/how-it-works.md`, `docs/customizing.md`): new sections covering all five configurable CLAUDE.md fields with options and effects. `docs/customizing.md` gains a quick-reference table at the top.

### Changed

- **`/rename` renamed to `/session-name`** (`templates/project/.claude/commands/session-name.md`): Claude Code has a built-in `/rename` command that renames the conversation window. The custom command was shadowing it, causing confusing behavior. Renamed to `/session-name`; all references in `wrap.md`, `post-merge.md`, `POST_MERGE_WORKFLOW.md`, `CONTEXT_SNAPSHOT.md`, `docs/how-it-works.md`, and `README.md` updated. Closes #121.

- **Manifest tracking extended to all files** (`install.sh`): the SHA256 manifest previously tracked only Rig-owned files. Now tracks all installed files. The Upgrade strategy can detect user customizations to any file (not just hooks/commands/processes) and protect them. The overwrite strategy received the same manifest-awareness: it warns and prompts before touching any user-customized file. Closes #118.

- **`--strategy upgrade` help text** (`install.sh`): updated from the stale "update Rig-owned files; preserve user-owned" to the accurate "auto-update unmodified Rig files; prompt on customized; skip user-owned".

- **Commit-msg hook language** (`templates/project/.husky/commit-msg`, `templates/project/.husky/post-commit`, `README.md`, `docs/customizing.md`): "AI attribution trailer stripping" reframed as "auto-injected tool footer removal". The hook strips footers inserted automatically by AI coding tools — not intentional credits. `docs/customizing.md` section rewritten to explain the default and when to disable it. Closes #132.

- **Two-layer architecture diagram** (`docs/how-it-works.md`): replaced with a three-box layout showing `~/tools/the-rig/` (the installer/repo) as the origin that produces both the global and project layers. Previous diagram omitted the installer entirely.

### Fixed

- **RIG_DIR resolution in all command files** (`templates/project/.claude/commands/`): all nine command files now include the `.rigpath` resolution block (`REPO=$(git rev-parse --show-toplevel); if [[ -f "$REPO/.rigpath" ]]; then RIG_DIR=...`). Commands that read or write `.rig/` paths now work correctly in stealth mode. Closes #125.

---

## [1.9.0] — 2026-05-06

### Added

- **GitHub Actions CI** (`.github/workflows/ci.yml`): runs the full bats test suite on every push to `main` and every PR. Catches install.sh regressions before they merge. Closes #114.
- **Issue template detection in `/ship` and `SHIP_WORKFLOW`** (`templates/project/.claude/commands/ship.md`, `templates/project/.rig/processes/SHIP_WORKFLOW.md`): Step 0/Step 2 now guide the agent to check `.github/ISSUE_TEMPLATE/`, select the appropriate template (`feature.md`, `bug.md`, etc.), strip YAML frontmatter, and use the body. Never use freeform issue bodies when templates exist. Closes #116.

### Changed

- **PR template detection now a hard gate** (`ship.md` Step 9, `SHIP_WORKFLOW.md` Step 6): checks all three common paths (`pull_request_template.md`, `PULL_REQUEST_TEMPLATE.md`, root-level). Language changed from advisory ("use it if one exists") to directive ("you MUST use it — never write freeform when a template is present"). Closes #116.

### Fixed

- **`overwrite` strategy now preserves user-owned files** (`install.sh`): the "Repair" option (intent 4 / `--strategy overwrite`) previously overwrote user-owned files (CLAUDE.md, rules, memory) in addition to Rig-owned files. "Repair" now resets only Rig infrastructure (hooks, commands, processes) — CLAUDE.md, rules, and memory files are never touched. Intent description updated to make this explicit. Closes #115.
- **`git symbolic-ref` exit-128 propagation** (`install.sh`): `git symbolic-ref` exits 128 when no remote origin exists (fresh repos, test environments). With `set -euo pipefail`, this propagated through the base-branch detection subshell and killed the installer with exit code 128. Fixed with `|| true`. All 53 bats tests now pass in non-interactive mode.
- **Non-interactive TTY guards on all `read` prompts** (`install.sh`): the base-branch prompt, project-name prompt, and upgrade customization dialog all blocked when stdin was not a TTY (CI, scripted installs, bats tests). All three now check `[[ -t 0 ]]` and fall back to auto-detected defaults in non-interactive contexts. Closes #115.

---

## [1.8.1] — 2026-05-06

### Fixed

- **pre-commit hook — grep pattern escaping** (`templates/project/.husky/pre-commit`): debug patterns like `console\.log(` used unescaped `(` in grep -E syntax, causing `empty (sub)expression` errors that blocked all commits. All parentheses in BUILTIN_PATTERNS are now escaped (`\(`). Closes gap found during 4Culture upgrade.
- **pre-commit hook — hook file self-scan** (`templates/project/.husky/pre-commit`): the script scanned its own source file (`.husky/pre-commit`) and flagged `debugger;` and `byebug` in the BUILTIN_PATTERNS definition as debug artifacts. Hooks directory (`.husky/*`, `.claude/hooks/*`) is now excluded from the staged file scan. Closes gap found during 4Culture upgrade. # rig-debug-ok
- **pre-commit hook — Husky `sh -e` compatibility** (`templates/project/.husky/pre-commit`): Husky runs hooks with `sh -e`. When `grep` finds no debug matches (exit 1), `sh -e` aborted the hook, falsely failing every commit. Added `|| true` after the grep call to prevent the false failure. Closes gap found during 4Culture upgrade.

---

## [1.8.0] — 2026-05-06

### Added

- **VERSION file** (`VERSION`, `templates/project/.rig/VERSION`): machine-readable version string at the repo root and in every installed project's `.rig/` directory. `cat .rig/VERSION` shows the installed Rig version instantly. `.rig/VERSION` is manifest-tracked so upgrades auto-update it. Closes #106.
- **`install.sh --version` flag**: prints `The Rig v<version>` and exits. Useful for scripts and debugging. Closes #106.
- **Stealth install mode** (`install.sh` tracking option 4): zero Rig traces in git for multi-contributor repos. Installs `.rig/` to an external path, adds all Rig artifacts (including `CLAUDE.md`, `.claude/`, `.github/`, `.gitleaks.toml`) to `.git/info/exclude`, and copies hooks directly to `.git/hooks/` — no Husky required. Teammates never see any Rig files. Closes #99.
- **Configurable housekeeping commit convention** (`templates/project/CLAUDE.md` `## Git workflow convention` section): controls how `/post-merge` handles memory-update commits. `housekeeping: direct-push` (default) commits directly to `main`; `housekeeping: pr-required` creates a short-lived branch and opens a PR. Documented in `docs/customizing.md`. Closes #98.
- **Branch safety check in `/ship`** (`SHIP_WORKFLOW.md` Step 3): blocks the ship workflow if on `main` or `master` and asks which branch to use. Prevents accidental commits directly to the default branch. Closes #97.
- **Git state checks in `/wrap` and `/post-merge`**: both commands verify the working tree and current branch before touching any files. Uncommitted changes are surfaced and resolved before proceeding. Closes #97.
- **`DECISIONS.md` template** (`templates/project/.rig/memory/DECISIONS.md`): committed memory file for architectural, product, and process decisions. Scaffolded with the per-entry format (Context / Decision / Rejected / Rationale / Consequences). Referenced in project `CLAUDE.md` context-loading sequence. Closes #78.

### Changed

- **`/post-merge`** (`POST_MERGE_WORKFLOW.md`, `commands/post-merge.md`): Step 1 now verifies state before pulling; Step 6 branches on `housekeeping: direct-push | pr-required` from project `CLAUDE.md`. Git state check section added to command file. Closes #98.
- **`docs/customizing.md`**: added "Option C — Stealth mode" section, housekeeping commit convention section, and DECISIONS.md section. Closes #96, #99.
- **`docs/how-it-works.md`**: "Three files, three purposes" updated to "Six files, six purposes"; DECISIONS.md subsection added; session lifecycle diagram updated. Closes #96.
- **`README.md`**: command count updated; DECISIONS added to memory file listing. Closes #96.
- **`is_rig_owned()`**: `.rig/VERSION` added to the list of Rig-owned files so upgrades auto-update the version marker. Closes #106.

### Fixed

- **bats tests** (`tests/test_install.bats`): 11 pre-existing test failures fixed by using the `run` helper for commands expected to exit non-zero, then checking `$status` instead of `$?`. Affected tests: `is_rig_owned` user-owned cases (6), sentinel-blocked cases (1), path-blocking allowed cases (3). All 51 tests now pass. Closes #104.

---

## [1.7.0] — 2026-04-30

### Added

- **`/doc-feature` slash command** (`templates/project/.claude/commands/doc-feature.md`): research a named feature end-to-end and produce a structured doc in `docs/features/`. Traces entry points, render logic, data model, business rules, and gotchas. Guards against duplicates — redirects to `/refresh-feature-doc` if the slug already exists. Updates `docs/features/README.md` index automatically.
- **`/refresh-feature-doc` slash command** (`templates/project/.claude/commands/refresh-feature-doc.md`): re-verify every claim in an existing feature doc against current code. Corrects stale paths and line numbers, flags removed fields, and logs any actual bugs found (not just doc inaccuracies) to `ERRORS.md`. Intended to run after any PR that touches a documented feature.
- **`docs/features/README.md` template** (`templates/project/docs/features/README.md`): scaffolded index for all feature docs. Imported by the project `CLAUDE.md` via `@docs/features/README.md` so every session knows the feature doc system exists and is loaded. Starts with a placeholder row that `/doc-feature` replaces on first use.
- **Feature documentation section in project `CLAUDE.md`**: adds `@docs/features/README.md` import and a 3-point guide (when to read, when to refresh, when to create) so every session knows the system exists and when to engage it. Originated as a project-level pattern in the 4Culture pilot.

### Changed

- **`templates/project/CLAUDE.md`**: repo structure tree updated to show `docs/features/` directory.
- **`docs/how-it-works.md`**: command count updated from 9 to 11; "Feature documentation" command group added to the command table.
- **`README.md`**: "What's included" table updated; command set section adds "Feature knowledge" group with `/doc-feature` and `/refresh-feature-doc`.

---

## [1.6.0] — 2026-04-30

### Added

- **Stop hook** (`templates/project/.claude/hooks/stop.sh`, wired as `"Stop"` event in `settings.json`): fires automatically when Claude Code's agent finishes its response (after each turn). Updates the `Last updated:` date in `CONTEXT_SNAPSHOT.md` (preserves the description — only the date changes) so the freshness signal stays accurate even when `/wrap` isn't run. Appends a `<!-- session-end YYYY-MM-DD HH:MM -->` boundary comment to `PROGRESS.md` — the heuristic in `/wrap` and `/post-merge` uses this to determine which entries belong to the current session. Idempotent: skips if a marker is already the last non-blank line. Documented in `docs/how-it-works.md` session lifecycle diagram and hook system section.
- **Session naming step** (`/wrap` step 8, `/post-merge` step 7): at wrap/post-merge time, agent reads this session's PROGRESS.md entries, derives a pipe-separated `/rename` command in `type short-desc #N | ...` format, and presents it as a ready-to-run command. User runs or tweaks it; agent never fires `/rename` automatically. Heuristic uses `<!-- session-end -->` markers (from stop.sh) as the primary session boundary signal, with `Last updated:` timestamp as fallback — robust across multi-day and resumed sessions. If session is already named (tracked in CONTEXT_SNAPSHOT `Session name:` field), suggests appending new work rather than replacing. Agent updates `Session name:` in CONTEXT_SNAPSHOT after user confirms.
- **`**Session name:**` field in CONTEXT_SNAPSHOT template**: allows /wrap and /post-merge to detect an existing session name and suggest appends on resume, avoiding accidental name replacement.

### Changed

- **`install.sh` — intent-first interactive flow**: the strategy question ("how do I handle file conflicts?") is replaced with an intent question ("What are you doing?"). Four intent options (First install / New project / Upgrade / Repair) each map to a pre-determined strategy and layer configuration; users no longer need to know what "merge" vs "upgrade" means. A fifth option (Custom) exposes the full strategy menu for power users. The "merge" strategy is retired from the visible menu but kept internally and accessible via `--strategy merge` for scripting and backward compatibility. Closes #73.
- **`install.sh` — component selection removed from main flow**: component selection is only shown for Custom (intent 5). All other intents install everything — no partial install prompts. Closes #73.
- **`install.sh` — default intent is "New project" (2)**: most runs are project scaffolding; First install (1) is for true first-timers who haven't set up the global layer yet. Closes #73.
- **`/wrap` session naming heuristic**: primary signal upgraded to `<!-- session-end -->` markers in PROGRESS.md (written by stop.sh); `Last updated:` timestamp now used as fallback. Makes boundary detection reliable regardless of agent memory between steps. Closes #74.
- **`/wrap` and `/post-merge` session naming**: both commands now check CONTEXT_SNAPSHOT for an existing `Session name:` and suggest appending rather than replacing when one is found.
- **`POST_MERGE_WORKFLOW.md`**: added session naming (new Step 7) and RIG_GAPS check to Step 5. Step 8 is now "Surface what's next". Command file and process file are now in sync. Closes #74.
- **`/post-merge` command**: step summary updated to include RIG_GAPS; session naming section updated to use session-end markers as primary boundary signal (consistent with `/wrap`). Closes #74.
- **`/kickoff` Step 0**: fixed wrong template path reference — now embeds the `PROJECT_BRIEF.md` template inline rather than referencing a path that doesn't exist in deployed projects. Closes #74.
- **`/new-feature` notes**: fixed incorrect cross-reference from `SHIP_WORKFLOW` to `NEW_TASK_WORKFLOW` for the GitHub issue requirement. Closes #74.
- **`PROGRESS.md` template**: added documentation for `<!-- session-end -->` boundary markers written by stop.sh. Closes #74.
- **`docs/how-it-works.md`**: updated session lifecycle diagram to show stop.sh behavior (fires after every agent turn); updated hook system section to document stop.sh; updated POST_MERGE_WORKFLOW summary to 8 steps including session naming; updated `/wrap` command table entry. Closes #74.
- **`README.md`**: added stop.sh note to session lifecycle section; added stop.sh row to hooks table. Closes #74.
- **`docs/customizing.md`**: Upgrade section updated to reflect intent-based menu (option 3 = Upgrade); strategy table replaced with intent table showing internal strategy mapping.

---

### Added

- **Stop hook** (`templates/project/.claude/hooks/stop.sh`, wired as `"Stop"` event in `settings.json`): fires automatically when Claude Code's agent finishes its response (after each turn). Updates the `Last updated:` date in `CONTEXT_SNAPSHOT.md` (preserves the description — only the date changes) so the freshness signal stays accurate even when `/wrap` isn't run. Appends a `<!-- session-end YYYY-MM-DD HH:MM -->` boundary comment to `PROGRESS.md` — the heuristic in `/wrap` and `/post-merge` uses this to determine which entries belong to the current session. Idempotent: skips if a marker is already the last non-blank line. Documented in `docs/how-it-works.md` session lifecycle diagram and hook system section.
- **Session naming step** (`/wrap` step 8, `/post-merge` step 7): at wrap/post-merge time, agent reads this session's PROGRESS.md entries, derives a pipe-separated `/rename` command in `type short-desc #N | ...` format, and presents it as a ready-to-run command. User runs or tweaks it; agent never fires `/rename` automatically. Heuristic now uses `<!-- session-end -->` markers (from stop.sh) as the primary session boundary signal, with `Last updated:` timestamp as fallback — robust across multi-day and resumed sessions. If session is already named (tracked in CONTEXT_SNAPSHOT `Session name:` field), suggests appending new work rather than replacing. Agent updates `Session name:` in CONTEXT_SNAPSHOT after user confirms. Originated as a RIG_GAPS report from the 4Culture project.
- **`**Session name:**` field in CONTEXT_SNAPSHOT template**: allows /wrap and /post-merge to detect an existing session name and suggest appends on resume, avoiding accidental name replacement.

### Changed

- **`install.sh` — intent-first interactive flow**: the strategy question ("how do I handle file conflicts?") is replaced with an intent question ("What are you doing?"). Four intent options (First install / New project / Upgrade / Repair) each map to a pre-determined strategy and layer configuration; users no longer need to know what "merge" vs "upgrade" means. A fifth option (Custom) exposes the full strategy menu for power users. The "merge" strategy is retired from the visible menu but kept internally and accessible via `--strategy merge` for scripting and backward compatibility.
- **`install.sh` — component selection removed from main flow**: component selection is only shown for Custom (intent 5). All other intents install everything — no partial install prompts.
- **`install.sh` — default intent is "New project" (2)**: most runs are project scaffolding; First install (1) is for true first-timers who haven't set up the global layer yet.
- **`/wrap` session naming heuristic**: primary signal upgraded to `<!-- session-end -->` markers in PROGRESS.md (written by stop.sh); `Last updated:` timestamp now used as fallback. Makes boundary detection reliable regardless of agent memory between steps.
- **`/wrap` and `/post-merge` session naming**: both commands now check CONTEXT_SNAPSHOT for an existing `Session name:` and suggest appending rather than replacing when one is found.
- **`POST_MERGE_WORKFLOW.md`**: added session naming (new Step 7) and RIG_GAPS check to Step 5. Step 8 is now "Surface what's next". Command file and process file are now in sync.
- **`/post-merge` command**: step summary updated to include RIG_GAPS; session naming section updated to use session-end markers as primary boundary signal (consistent with `/wrap`).
- **`/kickoff` Step 0**: fixed wrong template path reference — now embeds the `PROJECT_BRIEF.md` template inline rather than referencing a path that doesn't exist in deployed projects.
- **`/new-feature` notes**: fixed incorrect cross-reference from `SHIP_WORKFLOW` to `NEW_TASK_WORKFLOW` for the GitHub issue requirement.
- **`PROGRESS.md` template**: added documentation for `<!-- session-end -->` boundary markers written by stop.sh.
- **`docs/how-it-works.md`**: updated session lifecycle diagram to show stop.sh behavior (fires after every agent turn); updated hook system section to document stop.sh; updated POST_MERGE_WORKFLOW summary to include session naming step; updated `/wrap` command table entry to mention session naming.
- **`README.md`**: added stop.sh note to session lifecycle section; added stop.sh row to hooks table.
- **`docs/customizing.md`** Upgrade section: updated to reflect intent-based menu (option 3 = Upgrade); strategy table replaced with intent table showing internal strategy mapping.
- **`README.md`** quickstart and upgrade steps: updated to reference intent menu options instead of strategy numbers.

---

## [1.5.0] — 2026-04-29

### Added

- **`RIG_GAPS.md` template** (`templates/project/.rig/memory/RIG_GAPS.md`): self-improvement feedback log committed to every project repo. Captures workflow friction, bugs, missing features, and improvement ideas observed during real use. Accumulates across sessions and machines. Closes #72.
- **`/rig-gaps` slash command** (`templates/project/.claude/commands/rig-gaps.md`): compiles unsubmitted gap entries from `RIG_GAPS.md`, cross-checks `ERRORS.md` for Rig-related issues not yet captured, formats a consolidated report with copy-paste submission instructions, and offers to mark entries as submitted. Closes #72.
- **`/wrap` self-improvement check** (step 5): at session end, agent scans `ERRORS.md` for Rig-related friction and reflects on session pain points. Any gaps not already in `RIG_GAPS.md` are appended automatically. Closes #72.
- **`tests/test_install.bats`**: bats integration test suite for `install.sh`. Covers `is_rig_owned()` classification (11 cases), fresh install under skip/overwrite/upgrade strategies, overwrite backup creation, upgrade manifest generation, upgrade preservation of user-owned and `RIG_GAPS.md` files, settings.json creation, CLAUDE.md placeholder substitution, and CLI flag validation.
- **`install.sh` non-interactive flags**: `--strategy <name>` (skip/overwrite/merge/upgrade/interactive), `--target <path>`, and `--project-name <name>`. When these flags are provided, the corresponding interactive prompts and the git-tracking / component-selection questions are bypassed. Enables scripted installs and CI use. The `--help` output documents all flags.
- **`/run` RIG_GAPS reminder**: after presenting the task queue in Step 1, `/run` checks for unsubmitted entries in `.rig/memory/RIG_GAPS.md` and surfaces a soft reminder to run `/rig-gaps`. Non-blocking.

### Changed

- **`templates/project/.claude/commands/wrap.md`**: added step 5 (self-improvement check) with full entry format and submission reminder; existing steps 5–7 renumbered to 6–8.
- **`templates/project/.claude/commands/kickoff.md`**: Step 5 hand-off corrected — suggests `/run [first-task-slug]` instead of `/task` (which is the intake wizard, not the executor). Notes section updated with RIG_GAPS.md context.
- **`templates/project/.claude/commands/run.md`**: Step 1 expanded with RIG_GAPS unsubmitted-entries reminder.
- **`templates/project/.rig/processes/NEW_TASK_WORKFLOW.md`**: Step 7 (Wrap up) rewritten — adds plan-vs-reality audit before touching anything; structured `## Done notes` fields required (What was built / Deviations from plan / Actual files touched / Follow-ups opened); RIG_GAPS logging added as explicit step.
- **`templates/project/.rig/processes/SHIP_WORKFLOW.md`**: Step 4 updated — task file accuracy check added; GitHub Issue closing comment required when scope changes; RIG_GAPS logging added. Step 5 updated — PR body must describe what was actually built, not the original plan.
- **`templates/project/.rig/tasks/backlog/TASK_example.md`**: `## Done notes` section expanded with four structured fields to prevent restatement of plan.
- **`templates/project/.rig/memory/.gitignore`**: added comment confirming `RIG_GAPS.md` is intentionally tracked and committed.
- **`templates/project/.claude/commands/ship.md`**: Step 8 expanded to match `SHIP_WORKFLOW` Step 4 (task file accuracy check, four structured Done notes fields, ERRORS/RIG_GAPS logging, GitHub Issue closing comment). Step 9 opens with PR body accuracy requirement. Notes updated.
- **`templates/project/.claude/commands/task.md`**: Governance section notes RIG_GAPS logging at task completion.
- **`templates/project/.claude/commands/new-feature.md`**: workflow reference corrected from "Step 1" to "Step 0".
- **`templates/global/CLAUDE.md`**: hard rules header now reads "— 12 total".
- **`install.sh`**: `is_rig_owned()` comment documents `RIG_GAPS.md` as user-owned and never manifest-tracked. `--rig-dir` / `--target` / `--strategy` flag parsing refactored to a shared two-arg capture loop.
- **`docs/how-it-works.md`**: `RIG_GAPS.md` memory section added; `/rig-gaps` in command table (nine total); `NEW_TASK_WORKFLOW` and `SHIP_WORKFLOW` step summaries updated.
- **`docs/lessons-learned.md`**: count updated from ten to thirteen; lessons #10 and #11 numbering corrected (were swapped); two new lessons added — #12 (Merge strategy silently leaves Rig-owned files stale on upgrade) and #13 (task files and PRs describing the plan rather than the actual outcome).
- **`README.md`**: session start sequence updated (CONTEXT_SNAPSHOT is primary, PROGRESS is fallback); memory table includes RIG_GAPS.md; slash command count 8→9; `/rig-gaps` added to command set; hooks table updated for commit gate and sentinel cleanup.

---

## [1.4.0] — 2026-04-27

### Added

- **Versioned manifest + Upgrade strategy** (`install.sh`): new collision strategy option 5 — "Upgrade". On every install (any strategy), the installer now records the SHA256 of each Rig-owned file into `.rig/memory/.rig-manifest`. On upgrade with strategy 5: unmodified Rig-owned files are auto-updated; customized files show a diff and prompt before overwriting; user-owned files are always skipped. SHA256 unavailable gracefully falls back to `cmp -s` + prompt. Closes #69.
- **`.rig/memory/.rig-manifest` template file**: committed to the repo (not gitignored). Includes a header comment explaining its purpose. `.rig/memory/.gitignore` has an explicit comment confirming the manifest is intentionally tracked.
- **Commit gate with user trigger-phrase flow** (`pre-tool.sh`, `post-tool.sh`): agent pauses before any `git commit`, shows the proposed message, and asks for an explicit trigger phrase — "commit approved", "ship it", "lgtm", or "go". Agent creates `.rig-commit-ok` sentinel → commits → pushes. `post-tool.sh` auto-deletes the sentinel after the commit lands (one-shot authorisation). Closes #67.
- **`.rig-commit-ok` sentinel**: added to `.rig/memory/.gitignore` with lifecycle documentation.

### Changed

- **`install.sh`**: `copy_file()` gains an optional 4th parameter `rel` (relative path) used for manifest tracking and `is_rig_owned()` classification. New helpers: `sha256_file()`, `is_rig_owned()`, `read_manifest_hash()`, `write_manifest_entry()`, `_copy_file_upgrade()`. `MANIFEST_FILE` global resolved after `RIG_TRACKING` decision. All project-layer copy calls now pass `$rel`.
- **`templates/project/.rig/processes/SHIP_WORKFLOW.md`** Step 2.5: updated to use trigger-phrase language ("commit approved" / "ship it" / "lgtm" / "go").
- **`templates/project/.claude/commands/ship.md`** Steps 5 and 7: Step 5 uses trigger-phrase language; Step 7 creates the `.rig-commit-ok` sentinel inline (user already confirmed at Steps 5 + 6).
- **`templates/global/CLAUDE.md`** Hard Rule #11: rewritten to describe the full trigger-phrase protocol. Hard Rule count is now 12. Added compaction-warning instruction to Working style.
- **`templates/project/.rig/processes/NEW_TASK_WORKFLOW.md`**: fixed duplicate Step 1 — worktree orientation gate is Step 1, Orient is Step 2; Steps 2–6 renumbered to 3–7.
- **`docs/customizing.md`** Upgrade section: replaced stale "choose Merge" guidance with full Upgrade strategy documentation including manifest explanation, decision table, and manifest-aware customization guide.
- **`docs/how-it-works.md`**: hard rule count updated to 12; hook section documents commit-gate sentinel flow; SHIP_WORKFLOW and NEW_TASK_WORKFLOW step summaries updated; `.rig-manifest` added to memory system section.

---

## [1.3.0] — 2026-04-25

### Added

- **`/post-merge` slash command** (`templates/project/.claude/commands/post-merge.md`): wraps `POST_MERGE_WORKFLOW.md` into a runnable 7-step command — pull main, update PROGRESS, move task file, overwrite CONTEXT_SNAPSHOT, check ERRORS, housekeeping commit, surface next priority. Closes #51.
- **`.husky/post-merge` reminder hook** (`templates/project/.husky/post-merge`): fires after every `git merge` / `git pull` with a merge commit and prints a visible reminder to run `/post-merge` in Claude Code. Closes #52.
- **`CONTEXT_SNAPSHOT.md` template** (`templates/project/.rig/memory/CONTEXT_SNAPSHOT.md`): new template file that ships with The Rig. Includes a `Last updated:` header so staleness checks are deterministic — agent reads the date rather than inferring freshness from content. Closes #53.

### Changed

- **`templates/global/CLAUDE.md`**: added self-correction principle to Working style — "When the user corrects a mistake or changes an approach, update the relevant process, rule, or task file immediately." Corrections not written down repeat. Closes #53.
- **`templates/project/.rig/processes/SHIP_WORKFLOW.md`** Step 0: added label verification block (`gh label list`, `gh label create`) before `gh issue create` — fresh GitHub repos silently drop unknown labels without this check. Closes #53.
- **`templates/project/.rig/tasks/backlog/TASK_example.md`**: added `**Branch**:` field between GitHub issue and PR fields so branch name is tracked alongside PR number. Closes #53.

### Fixed

- **`install.sh`**: Husky init failure no longer kills the install. `npx husky install` is now wrapped in an `if` block — on failure, a warning is printed with manual recovery instructions instead of aborting the entire script. Closes #47.
- **`templates/project/.claude/commands/run.md`**: `/run` no longer queues `TASK_example.md` as a real task. The example file has `Status: backlog` and `Priority: P0`; the command now explicitly skips any file named `TASK_example.md`. Closes #49.
- **`templates/project/.husky/filter-commit-message-inplace.sh`**: `Co-authored-by:` stripping is now scoped to known AI tools only (Claude, Cursor, Copilot, `noreply@anthropic.com`, etc.). Previously stripped all `Co-authored-by:` lines including legitimate human pair-programmers. Closes #50.
- **`.gitignore`**: removed stale pre-consolidation path (`templates/project/memory/CONTEXT_SNAPSHOT.md`); `CONTEXT_SNAPSHOT.md` in deployed projects is correctly ignored via `.rig/memory/.gitignore`.

---

## [1.2.0] — 2026-04-19

### Added

- **`.rig/` subdirectory**: `memory/`, `processes/`, `rules/`, and `tasks/` are now installed under `.rig/` in the target project (e.g. `.rig/memory/PROGRESS.md`, `.rig/tasks/active/`). Keeps the project root clean — The Rig's files are clearly separated from application code.

### Changed

- `templates/project/CLAUDE.md`: repo structure diagram and context-loading sequence updated for `.rig/` paths. `@rules/` imports updated to `@.rig/rules/`.
- `templates/global/CLAUDE.md`: context profile and memory discipline sections updated for `.rig/` paths.
- All 8 slash command files: path references updated to `.rig/memory/`, `.rig/tasks/`, `.rig/processes/`, `.rig/rules/`.
- All 4 process files: path references updated to `.rig/` prefix.
- `templates/project/.claude/hooks/pre-tool.sh`: `RIG_PROTECTED` array updated — `processes/` → `.rig/processes/`, `rules/` → `.rig/rules/`.
- `templates/project/.claude/hooks/post-tool.sh`: `PROGRESS_FILE` path updated to `$REPO/.rig/memory/PROGRESS.md`.
- `install.sh`: component selection prompts and `should_install_file()` path mappings updated for `.rig/` prefix.
- `docs/how-it-works.md`, `docs/customizing.md`, `README.md`: architecture diagrams and path references updated throughout.

### Fixed

- `README.md`: quickstart restructured around the permanent-install flow (`~/tools/the-rig`). SSH clone URL added alongside HTTPS. Named-clone tip added. Separate sections for first-time setup, new project, drop-in, and upgrade.
- `install.sh`: when run from inside the target project directory (in-place clone), now detects this condition and offers to remove The Rig's own source files (`templates/`, `docs/`, `CHANGELOG.md`, `install.sh`, `LICENSE`, `README.md`) after scaffolding. Opt-in with explicit file list shown before removal.

---

## [1.1.0] — 2026-04-10

### Added

- `docs/customizing.md`: upgrade path section — re-run installer with Merge strategy to pick up new template files without overwriting customizations
- `docs/lessons-learned.md`: lesson #11 — moving/renaming the project directory after install breaks Claude Code hooks silently; documents fix (re-run installer) and watch-for (check session log)

### Changed

- `install.sh`: collision strategy is now selected once upfront (Interactive / Skip / Overwrite / Merge) rather than per-file prompt. Overwrite mode backs up originals to `.rig-backup/<timestamp>/`. Merge mode smart-merges `.claude/settings.json` via Python 3, deduplicating by command string — idempotent and safe to run twice.
- `install.sh`: component selection added — choose all or select individual groups (memory, tasks, processes, rules, hooks, commands, git hooks, GitHub templates, CLAUDE.md, PROJECT_BRIEF.md)
- `install.sh`: project name input sanitized before `sed` substitution — strips metacharacters that would corrupt `CLAUDE.md`
- `templates/global/CLAUDE.md`: CONTEXT_SNAPSHOT-first context load — PROGRESS.md is only loaded when snapshot is absent or stale; scoped to last 20 entries when loaded
- `templates/project/CLAUDE.md`: same CONTEXT_SNAPSHOT-first load instruction
- `templates/project/.claude/commands/wrap.md`: PROGRESS.md trim step added — when entry count exceeds 20, offers to move oldest entries to `PROGRESS_archive.md` (gitignored, disk-only); always confirmed, never automatic
- `templates/project/.claude/commands/propose.md`: post-approval apply flow clarified — agent cannot apply changes to governance files directly (pre-tool.sh blocks it unconditionally); human applies via editor paste or "show me the apply block" shortcut
- `templates/project/.claude/hooks/pre-tool.sh`: approved change flow documented in RIG_PROTECTED comment block
- `templates/project/memory/PROGRESS.md`: trim convention documented
- `templates/project/memory/.gitignore`: `PROGRESS_archive.md` added
- `docs/how-it-works.md`: session lifecycle diagram updated for CONTEXT_SNAPSHOT-first load; slash commands table expanded from 4 to all 8, grouped by purpose; autonomy system section added
- `docs/customizing.md`: PROJECT_BRIEF.md added to customization table; intake wizard defaults section added; /propose governance gate section added; upgrade path section added
- `README.md`: quickstart step 4 updated from "fill in CLAUDE.md manually" to "run /kickoff"; installer step updated to reflect collision strategy and component selection

---

## [1.0.0] — 2026-04-10

First stable release. Built and refined across 100+ PRs on the LaudBot project.

### Added

**Global layer** (`templates/global/`)
- `CLAUDE.md` — global identity template with 11 hard rules, working style, memory discipline, planning discipline, session workflow, git conventions, code quality defaults, and skill trigger table
- `PROFILE.md.example` — personal context template for `~/.your-ai-contexts/`
- `skills/debug.md` — hypothesis-first debugging, mandatory ERRORS.md log
- `skills/code-review.md` — severity triage, blockers-first reporting
- `skills/refactor.md` — read before touching, plan before implementing
- `skills/write-tests.md` — list cases first, test behaviour not implementation
- `skills/explain.md` — audience-calibrated, one-sentence answer first

**Project layer** (`templates/project/`)
- `CLAUDE.md` — project brain template with stack table, conventions, off-limits paths, session context-loading sequence, `@rules/` imports, and "Project context for task mode" section
- `PROJECT_BRIEF.md` — greenfield project brief template covering goal, users, MVP features, out-of-scope, stack choices, constraints, success metrics, and open questions
- `processes/NEW_TASK_WORKFLOW.md` — 6-step task start process with working-directory orientation gate
- `processes/SHIP_WORKFLOW.md` — issue-first rule, pre-ship checklist, PR template enforcement, label discipline
- `processes/DEBUG_WORKFLOW.md` — hypothesis-first debugging, mandatory ERRORS.md entry
- `processes/POST_MERGE_WORKFLOW.md` — pull → PROGRESS → task move → CONTEXT_SNAPSHOT → next priority
- `rules/coding-standards.md` — language-agnostic structure with fill-in sections per runtime
- `rules/git-conventions.md` — conventional commits, branch naming, PR checklist
- `rules/security.md` — non-negotiables, auth rules, API hardening, environment hygiene
- `rules/verification.md` — in-container smoke test protocol for Docker/dependency changes
- `memory/PROGRESS.md` — append-only build log template
- `memory/ERRORS.md` — pitfall log template with example entry
- `memory/CONTEXT_SNAPSHOT.md` — session state template (gitignored)
- `memory/.gitignore` — excludes CONTEXT_SNAPSHOT.md from version control
- `tasks/backlog/TASK_example.md` — complete task file template with `## Depends on` and `## Operating mode` fields
- `tasks/active/.gitkeep`, `tasks/done/.gitkeep`
- `.claude/settings.json` — PreToolUse and PostToolUse hook wiring with stable `[REPO_ROOT]` path substitution
- `.claude/hooks/pre-tool.sh` — write protection for governance files (`RIG_PROTECTED` block) and configured project paths; PascalCase tool name matching
- `.claude/hooks/post-tool.sh` — PROGRESS.md auto-stub after git commits
- `.claude/commands/kickoff.md` — `/kickoff` greenfield bootstrap: reads PROJECT_BRIEF.md, resolves open questions, scaffolds CLAUDE.md + task backlog + GitHub issues in one pass
- `.claude/commands/task.md` — `/task` intake wizard: three-part order (goal/context/constraints → autonomy/check-ins/risk → confirmation); persists operating mode in task file
- `.claude/commands/run.md` — `/run` execution loop: dependency-aware priority queue, per-task autonomy level enforcement, automatic chaining at High autonomy
- `.claude/commands/propose.md` — `/propose` governance gate: writes change proposal to `/tmp/`, waits for human approval before touching any governance file
- `.claude/commands/new-feature.md` — `/new-feature` slash command
- `.claude/commands/ship.md` — `/ship` slash command
- `.claude/commands/debug.md` — `/debug` slash command
- `.claude/commands/wrap.md` — `/wrap` session-end slash command
- `.husky/pre-commit` — gitleaks secret scanning (PATH-safe)
- `.husky/commit-msg` — AI attribution trailer stripping
- `.husky/post-commit` — post-commit trailer re-injection fix
- `.husky/filter-commit-message-inplace.sh` — shared filter for Cursor, Claude, Copilot patterns
- `.gitleaks.toml` — extends default ruleset with placeholder allowlist
- `.github/PULL_REQUEST_TEMPLATE.md`
- `.github/ISSUE_TEMPLATE/feature.md`, `bug.md`, `chore.md`

**Installer**
- `install.sh` — interactive setup for global and project layers; handles `[REPO_ROOT]` path substitution (GNU/BSD sed compatible), executable bits, Husky initialization, gitleaks check

**Documentation**
- `docs/how-it-works.md` — architecture deep-dive with diagrams
- `docs/decisions.md` — 10 key design decisions with rationale and tradeoffs
- `docs/lessons-learned.md` — 10 documented pitfalls from the LaudBot pilot
- `docs/customizing.md` — adapting The Rig for any stack
