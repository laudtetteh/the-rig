# Project Brief: The Rig

---

## What is this?

**One-liner:** A workflow system that makes Claude Code and Codex sessions consistent, recoverable, and production-safe across any project.

The shared `.rig` workflow is provider-neutral. Claude commands/hooks and Codex skills/hooks are adapters over that layer; provider-native lifecycle and configuration details remain explicitly labeled.

**Problem statement:** Agent sessions are stateless and ephemeral. Without structure, every Claude Code or Codex session starts from scratch: no memory of what was built, no enforced process for shipping, no protection against common mistakes (committing secrets, writing to wrong directories, making architectural decisions without review). Left unchecked, an AI coding agent is fast but fragile — great for individual files, unreliable for multi-session projects.

**Solution:** The Rig installs a persistent memory system, governed process workflows, provider adapters that enforce safety rules, and command/skill surfaces that implement consistent patterns (task intake, PR shipping, session wrap). The installer is a single Bash script that scaffolds these files into any project. Once installed, the agent follows The Rig's processes rather than improvising — producing consistent, auditable results across sessions.

---

## Who is it for?

**Primary user:** Developers using Claude Code or Codex as an AI coding tool on real projects — not demos, not one-off scripts.

**Secondary user:** Teams where engineers use Claude Code and/or Codex on a shared repo; The Rig's stealth mode keeps it invisible to teammates who don't use it.

**Scale at launch:** Solo developers and small teams (1–5 engineers), including concurrent sessions across supported agents.

---

## What it ships

The Rig is actively developed, currently at v1.23.0 with a v1.24.0 release pending
tag. These are the shipped components:

### Installer (`install.sh`)
- Single-file Bash installer with seven strategies: merge (new install), skip,
  overwrite, upgrade, interactive, plus agent-driven `agent-plan` (read-only JSON
  preview) and `agent-upgrade` (applies safe convergence, JSON result, exit 3 on
  any unresolved conflict)
- Manifest tracking (SHA256 of all installed files, plus a JSON companion
  carrying per-artifact provenance: `owner`/`source`/`generator`/`provider`/
  `base_revision`) — upgrade strategy detects user customizations before
  overwriting, and refuses to trust a `base_revision` claiming a newer
  installer version than the one running
- Stealth mode: all Rig artifacts excluded from git; `.rig/` at external path;
  hooks in `.git/hooks/` (manifest-tracked and backed up, with a safe lifecycle
  under agent-driven upgrades)
- Non-interactive mode (`--strategy`, `--target`, `--tracking`, `--base-branch`
  flags) for scripting and CI
- Self-install detection, `[BASE_BRANCH]` and `[REPO_ROOT]` placeholder substitution
- 594 bats tests across 40 files

### Project layer (scaffolded into target projects)
- **Memory system**: `PROGRESS.md` (auto-logged by post-commit hook), `ERRORS.md`, `CONTEXT_SNAPSHOT.md` (written by `/wrap`), `DECISIONS.md`, `RIG_GAPS.md`
- **Processes**: `NEW_TASK_WORKFLOW.md`, `SHIP_WORKFLOW.md`, `POST_MERGE_WORKFLOW.md`, `DEBUG_WORKFLOW.md`
- **Command/skill adapters**: Claude slash commands are generated as corresponding Codex `$name` skills from one canonical source
- **Agent hooks**: canonical Claude handlers plus a Codex hook manifest/adapter enforce the same safety and lifecycle contracts
- **Git hooks**: `pre-commit` (gitleaks secret scanning), `commit-msg` + `post-commit` (tool footer removal), `post-merge` (post-merge-pending flag)
- **Configurable project settings**: `issue-tracking`, `secret-scanner`, `commit-cleanup`, `base-branch`, `housekeeping`

### Global agent layers
- Claude: `~/.claude/CLAUDE.md` plus personal skills
- Codex: generated personal skills under `~/.agents/skills/`

---

## What shipped in the 1.23.0 → 1.24.0 window

- **Agent-driven convergence**: `agent-plan`/`agent-upgrade` strategies with a
  JSON result contract and exit-3 refusal semantics; `/rig-upgrade` now wires
  its Phase 2 to this orchestrator via `--mode=agent` (default) / `--mode=classic`
- **Manifest provenance**: `base_revision`/`generator`/`provider` fields on every
  manifest entry, plus future/bogus `base_revision` gating (a claimed revision
  newer than the running installer is refused, not silently trusted)
- **Fixed stealth-exclusion coverage**: every generated launcher sibling under
  `bin/` is now git-excluded (closes a leak affecting real installed projects)
- **Complete transaction/backup coverage**: direct-writer mutations (including
  `.claude/settings.json` merges) are now journaled and recoverable
- **Safe stealth `.git/hooks/` lifecycle**: hooks are manifest-tracked, backed
  up before overwrite, and agent-upgrade refuses on customization
- **`bin/rig doctor`**: 5 postflight gates (`manifest_provenance`,
  `stealth_status`, `manifest_mode_hash`, `stale_manifest_entries`, `idempotence`)

---

## Not in scope

- GUI or web interface
- Cloud sync of memory files
- Native Windows support (POSIX Bash; WSL2 works)
- Providers beyond Claude Code and Codex

---

## Stack

| Layer | Choice |
|---|---|
| Installer | Bash — single file, no runtime dependencies, `set -euo pipefail` |
| Templates | Markdown (commands, processes, rules) + Bash (hooks) |
| Tests | bats-core |
| CI | GitHub Actions |
| Hosting | GitHub (source only — no server) |

---

## Constraints

**Timeline:** Ongoing — shipped, actively maintained

**Must NOT use:** Runtime dependencies in `install.sh` beyond standard POSIX utils + `git`, `gh`, `gitleaks` (optional)

**Existing code:** This IS the existing code — `install.sh` at v1.23.0 (v1.24.0 pending tag)

---

## Success metrics

- Upgrade path never breaks an existing install
- All 594 bats tests pass on every commit (hosted CI is the authoritative gate)
- A new user can install The Rig and complete a first Claude `/task` → `/ship` or Codex `$task` → `$ship` cycle without reading docs
- Memory survives context compaction — next session picks up exactly where the last one left off

---

## Open questions / backlog themes

- [ ] `[BASE_BRANCH]` substitution corrupts manifest hash for process files — causes
      false "Customized file detected" on next upgrade (still genuinely open; see
      `ERRORS.md` and `CLAUDE.md`'s "Known gotchas")
