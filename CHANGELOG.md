# Changelog

All notable changes to The Rig are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

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
