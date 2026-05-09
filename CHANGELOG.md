# Changelog

All notable changes to The Rig are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- `GLOBAL_MANIFEST_FILE` (`~/.claude/.rig-global-manifest`) tracks SHA256 of installed global files
- `_copy_global_file_upgrade()` — manifest-aware upgrade handler for global layer files
- Interactive intent 3 (Upgrade) now also syncs the global layer (`DO_GLOBAL=true`)
- Global upgrade: auto-extracts existing `PROFILE_PATH` from installed `~/.claude/CLAUDE.md` (no prompt)
- Global upgrade: `PROFILE.md` is never touched (personal data, always off-limits)
- 2 new bats tests for global upgrade behavior (75 total)
- **Multi-tracker issue enforcement** (`templates/project/CLAUDE.md`, `templates/project/.claude/commands/task.md`, `templates/project/.rig/processes/NEW_TASK_WORKFLOW.md`, `templates/project/.husky/commit-msg`): expanded issue-tracking support from GitHub-only to Linear, Trello, and GUS. `CLAUDE.md` now documents all five `issue-tracking:` values (`github`, `linear`, `trello`, `gus`, `none`) with per-tracker ref formats. Added `issue-creator:` field (`user` | `agent`) with `agent` only applying to GitHub. The `/task` intake wizard handles all tracker types in question 4. `NEW_TASK_WORKFLOW.md` Step 0 updated to document all trackers and their required ticket validation rules. `commit-msg` hook Step 3 now validates per-tracker ref format (`[#N]` for GitHub, `[TEAM-123]` for Linear, `[trello:ID]` for Trello, `[W-N]` for GUS, no check for `none`). 6 new bats tests (79 total). Closes #155.

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
