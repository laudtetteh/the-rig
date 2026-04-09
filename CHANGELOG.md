# Changelog

All notable changes to The Rig are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] — 2026-04-09

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
- `CLAUDE.md` — project brain template with stack table, conventions, off-limits paths, session context-loading sequence, and `@rules/` imports
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
- `tasks/backlog/TASK_example.md` — complete task file template
- `tasks/active/.gitkeep`, `tasks/done/.gitkeep`
- `.claude/settings.json` — PreToolUse and PostToolUse hook wiring
- `.claude/hooks/pre-tool.sh` — write protection for configured paths (PascalCase tool names)
- `.claude/hooks/post-tool.sh` — PROGRESS.md auto-stub after git commits
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
- `install.sh` — interactive setup for global and project layers; handles path substitution, executable bits, Husky initialization, gitleaks check

**Documentation**
- `docs/how-it-works.md` — architecture deep-dive with diagrams
- `docs/decisions.md` — 10 key design decisions with rationale and tradeoffs
- `docs/lessons-learned.md` — 10 documented pitfalls from the LaudBot pilot
- `docs/customizing.md` — adapting The Rig for any stack
