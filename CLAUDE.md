# The Rig — project brain

> This file is loaded automatically by Claude Code at the start of every session in this repo.
> Installed in stealth mode — this file is excluded from git tracking.
> Universal rules (working style, hard rules, git conventions) live in ~/.claude/CLAUDE.md.

---

## What this project is

The Rig is a Claude Code and Codex workflow system — a structured set of memory files, commands/skills, hook adapters, process workflows, and an installer — that makes agent sessions consistent, recoverable, and production-safe. It ships as an installer repo (`install.sh` + `templates/`) that scaffolds files into any project. Once installed, the project layer runs autonomously: hooks auto-log commits to `PROGRESS.md`, session memory persists across compactions, and every major workflow (task intake, PR shipping, post-merge housekeeping, session wrap) follows a governed process. The Rig itself is developed using The Rig.

---

## Stack

| Layer | Technology |
|---|---|
| Installer | Bash (`install.sh`) — single-file public entry point with Python helpers for structured merges/generation |
| Hooks | Bash scripts (`.claude/hooks/`, `.codex/hooks/`, `.husky/`, `.git/hooks/`) |
| Commands | Markdown (`.claude/commands/*.md`) plus generated Codex skills; repo-local internal mirrors may also live under ignored `.claude/commands/` and `.codex/skills/` |
| Processes | Markdown (`.rig/processes/*.md`) — step-by-step agent workflows |
| Tests | [bats-core](https://github.com/bats-core/bats-core) — complete installer, command, hook, and parity coverage |
| CI | GitHub Actions (`.github/workflows/ci.yml`) — the complete suite runs on every push and PR, sharded across an 8-job dynamic matrix (weighted by `tests/.ci-shard-weights.json`; was one sequential job at 45-48 min before issue #505/PR #506, 2026-08-09). Wall-clock was ~8 min at #505; the heavy upgrade suites added by PR #569 pushed the slowest shard to ~18 min — tracked in #570 |
| Versioning | `VERSION` file + `CHANGELOG.md` + git tags (`vX.Y.Z`) |

---

## Repo structure

```
the-rig/
├── install.sh            # Single-file installer — the public entry point
├── VERSION               # Current version string (e.g. "1.10.1")
├── CHANGELOG.md          # Keep-a-Changelog format, every release documented
├── README.md             # Public-facing documentation
├── templates/
│   ├── global/           # Files installed to ~/.claude/ (CLAUDE.md, skills/)
│   └── project/          # Files scaffolded into target projects
│       ├── .claude/      # hooks/, commands/, settings.json
│       ├── .husky/       # Git hook scripts (pre-commit, commit-msg, post-commit, post-merge)
│       ├── .github/      # PR and issue templates
│       └── .rig/         # memory/, processes/, rules/, tasks/, VERSION
├── docs/                 # Architecture and user documentation
│   ├── how-it-works.md
│   ├── customizing.md
│   ├── lessons-learned.md
│   ├── troubleshooting.md
│   └── decisions.md
└── tests/                # bats test suite
    └── *.bats
```

> **Stealth mode:** `.rig/` lives at `~/.rig/projects/the-rig/`. `.claude/`, `.codex/`,
> `.agents/`, `CLAUDE.md`, `PROJECT_BRIEF.md`, `.gitleaks.toml`, `.github/`, and
> `docs/features/README.md` are git-excluded. `.rigpath` at the repo root points to the external `.rig/` directory.
> Git hooks are installed to `.git/hooks/` (no Husky).

---

## Project context for task mode

- **Entry point**: `install.sh` — all installer logic lives here; read it before touching it
- **Template source**: `templates/project/` and `templates/global/` — these are copied to target projects; changes affect all future installs
- **Repo-local internal workflows**: ignored `.claude/commands/` and `.codex/skills/` files can hold dogfood-only commands such as `rig-release-pilot`; keep them out of `templates/` unless explicitly deciding to ship them downstream.
- **Test suite**: `tests/` (61 files, 834 tests as of PR #569 (v1.29.1 not yet cut)) — CI runs the complete suite sharded across 8 parallel jobs (`.github/workflows/ci.yml`, issue #505); use focused files locally while editing, never a full local `bats tests/` run (see "Key conventions" below)
- **Key installer functions**: `copy_file()`, `_copy_file_upgrade()`, `is_rig_owned()`, `read_manifest_hash()`, `write_manifest_entry()`, `merge_settings_json()`, `backup_file()`
- **Manifest**: `/Users/beaconavenue/.rig/projects/the-rig/memory/.rig-manifest` in the target project — SHA256 hashes of all installed files; the upgrade strategy uses it to detect user customizations
- **Version bumps**: update `VERSION`, add entry to `CHANGELOG.md`, PR on `chore/release-vX.Y.Z` branch, tag after merge
- **Release flow**: PR → merge → `git tag vX.Y.Z` → `git push origin vX.Y.Z` → `gh release create`

---

## Known gotchas — read before touching install.sh

- **`set -euo pipefail` is active.** Any non-zero exit kills the script. `grep` with no match exits 1 — always append `|| true` to grep pipelines where no-match is valid.
- **`main` substitution refreshes the manifest hash immediately (fixed by #498, 2026-08-09).** `_subst_base_branch()` and the external/stealth `@/Users/beaconavenue/.rig/projects/The Rig/` CLAUDE.md rewrite both call `write_manifest_entry()` right after their `sed_inplace` calls, so the manifest reflects the actual post-substitution on-disk content from the moment it's written — not a stale pre-substitution hash. Previously this was a documented "known false positive": the manifest recorded the pre-substitution hash, so the very next upgrade showed a "Customized file detected" false positive for every process/command file containing `main`. That is no longer expected behavior — if you see it again, it's a regression, not a known quirk.
- **Self-install detector fires** when `install.sh` is run from inside the target project directory. It offers to clean up template source files. The detector is guarded: if `install.sh` is git-tracked (i.e. we're inside the Rig's own repo), cleanup is silently skipped.
- **Use `--tracking` for non-interactive tracking mode selection.** `--target` and `--tracking` are orthogonal: `--target` sets the path, `--tracking repo|local|external|stealth` sets tracking mode. For a clean stealth install: `./install.sh --target <path> --tracking stealth --project-only --strategy merge`.
- **Manifest `is_rig_owned()` is load-bearing.** The upgrade strategy uses it to decide what to auto-update vs. skip. New template files need a classification decision.
- **`bin/rig` at the repo root is a stale, untracked dev-tooling copy — never the real source.** This repo dogfoods itself, and `bin/rig` exists in two places that can silently diverge: the repo root's own copy (untracked, `.git/info/exclude`d, refreshed via `bin/rig worktree bootstrap`) and `templates/project/bin/rig` (tracked — the file actually shipped to every downstream project). Before editing `bin/rig` behavior, confirm which copy you're looking at with `git ls-files bin/rig templates/project/bin/rig` — the working file's presence or absence in that output is definitive. `git status --short bin/rig` showing nothing at all, even right after an edit, is itself the tell you're on the untracked dev copy. (See `docs/lessons-learned.md` #16.)

---

## Key conventions

- **Never break the upgrade path.** Every `install.sh` change must be tested against a project installed with a prior version. The `bats` tests cover this.
- **Placeholders use `[SCREAMING_CASE]` brackets** throughout templates: `main`, `[REPO_ROOT]`, `the-rig`. Substitution runs via `sed` after file copy.
- **CI is the authoritative complete-suite gate.** Before committing, run syntax/lint, ticket-focused tests, nearby regressions, live/adversarial validation, and review the complete staged diff. Run a local `bats tests/` only for an explicit coordinator exception (CI diagnosis, CI/test-harness work, an uncovered interaction, or CI unavailability). **This applies to dispatched review/verification subagents too — state the "never run the full suite" constraint explicitly in every such subagent's prompt.** A fresh subagent has no reason to read this file or `rules/verification.md` unless told to, and has been observed drifting into a full local run on its own initiative when the constraint wasn't spelled out for it.
- **Command files are written for an agent, not a checklist reader.** Every step must be unambiguous and self-contained. No "see above" references.
- **Lessons learned (`docs/lessons-learned.md`) is append-only.** Document real incidents only. Never rewrite existing entries.

---

## Base branch

```
base-branch: main
```

---

## Git workflow convention

```
housekeeping: direct-push
```

---

## Project settings

```
issue-tracking: github
secret-scanner: gitleaks
commit-cleanup: yes
```

---

## Off-limits — never touch without explicit instruction

- `templates/` contents — source of truth for what gets installed; every edit here ships to all future users
- `tests/` — do not delete or weaken tests; add new tests when adding installer behaviour
- `.git/hooks/` — installed by stealth setup; do not modify manually
- `docs/lessons-learned.md` — historical record; additions only, no rewrites of existing entries

---

## How to run locally

```bash
# Run a specific test file (normal local workflow — see "Key conventions"
# above for why a full local `bats tests/` run isn't the default: hosted
# CI's sharded matrix is the authoritative complete-suite gate, and a local
# sequential run of everything still takes ~45-48 min regardless of the
# CI-side sharding, which only parallelizes the hosted matrix's own runners)
bats tests/test_install_a.bats

# Test the installer against a throwaway project
mkdir /tmp/test-project && git -C /tmp/test-project init
./install.sh --project-only --target /tmp/test-project --strategy merge

# Check installer syntax
bash -n install.sh
```

---

## Upstream release review — mandatory planning prerequisite

Before `/sprint`, backlog-wide ticket triage, or any multi-ticket planning in
this repository:

1. Resolve `RIG_DIR` from `.rigpath` and read
   `$RIG_DIR/memory/UPSTREAM_RELEASE_AUDIT.md`.
2. Check the official Claude Code and Codex release sources recorded there,
   starting strictly after each last-reviewed tag. Also record the locally
   installed versions from `claude --version` and `codex --version` when those
   commands are available.
3. Use a full review instead of the incremental cursors when the user requests
   it, a cursor is missing or malformed, or upstream history was rewritten.
4. Validate relevant changelog findings against the current repository, then
   deduplicate them against open and closed GitHub issues and local task files
   before creating, changing, or sprint-scheduling tickets.
5. Update the audit log with review dates, source URLs, newest reviewed tags,
   installed versions, findings, and affected issue numbers before presenting
   the plan.

If either official source cannot be checked, show a visible stale-release-data
warning naming the failed source and current cursor. Do not continue planning
until the user explicitly chooses whether to proceed with stale data.

This prerequisite applies only while developing The Rig itself. Never add it
to `templates/` or make it a downstream Rig capability.

---

## Context files — load at session start

When starting a new session, read in this order:

1. `/Users/beaconavenue/.rig/projects/the-rig/memory/CONTEXT_SNAPSHOT.md` — if present, sufficient for orientation; stop here
2. `/Users/beaconavenue/.rig/projects/the-rig/memory/PROJECT_CONVENTIONS.md` — durable user-approved operating rules
3. `/Users/beaconavenue/.rig/projects/the-rig/memory/PROGRESS.md` — only if snapshot absent or more than one session old
4. `/Users/beaconavenue/.rig/projects/the-rig/memory/ERRORS.md` — known pitfalls
5. `/Users/beaconavenue/.rig/projects/the-rig/memory/DECISIONS.md` — skim only
6. `/Users/beaconavenue/.rig/projects/the-rig/tasks/active/` — in-flight tasks

---

## Imported rules

@/Users/beaconavenue/.rig/projects/the-rig/rules/coding-standards.md
@/Users/beaconavenue/.rig/projects/the-rig/rules/git-conventions.md
@/Users/beaconavenue/.rig/projects/the-rig/rules/security.md
@/Users/beaconavenue/.rig/projects/the-rig/rules/verification.md
