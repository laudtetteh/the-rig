# [Project Name] — project brain

> This is the Claude-native compatibility source for a project that may run Claude Code and Codex. Shared `.rig` rules apply to either provider; Codex uses its configured context/skill adapter and does not imply Claude-only execution.

> Claude Code loads this file natively. Codex loads it through The Rig's configured
> project-instruction fallback unless a native `AGENTS.override.md` or `AGENTS.md`
> takes precedence.
> Fill in every [PLACEHOLDER]. Delete sections that don't apply.
> Keep it lean — only things specific to this project belong here.
> Claude global rules live in `~/.claude/CLAUDE.md`; Codex uses its supported
> global instructions and generated personal skills.

---

## What this project is

[One paragraph: what it does, who it's for, and why it exists.]

---

## Stack

| Layer | Technology |
|---|---|
| Backend | [e.g. FastAPI / Python 3.12, port 8000] |
| Frontend | [e.g. Next.js / Node 20, port 3001] |
| Database | [e.g. PostgreSQL, Redis] |
| Auth | [e.g. JWT — invite-based, or OAuth via ...] |
| Infra | [e.g. Docker + Docker Compose locally; GitHub Actions CI] |
| Testing | [e.g. pytest + Vitest, or TBD] |

---

## Repo structure

```
[project-name]/
├── .claude/          # Claude Code config (hooks, commands)
├── .agents/skills/   # generated Codex skills from canonical commands
├── .codex/           # Codex config and hook adapter
├── .github/          # PR and issue templates
├── .husky/           # Git hooks
├── [backend/]        # Backend application
├── [frontend/]       # Frontend application
├── .rig/             # The Rig system files
│   ├── memory/       # PROGRESS.md, ERRORS.md, CONTEXT_SNAPSHOT.md (gitignored)
│   ├── processes/    # Agent workflow files
│   ├── rules/        # Coding standards, git conventions, security, verification
│   └── tasks/        # active/, backlog/, done/
├── docs/
│   ├── INDEX.md      # Canonical docs index (`docs/INDEX.md`); one row per docs file
│   ├── architecture/ # System design, runtime flow, integration notes
│   ├── decisions/    # Decision records and tradeoff notes
│   ├── troubleshooting/ # Symptoms, causes, and fixes
│   └── features/     # Feature docs (README.md index + one .md per feature)
├── CLAUDE.md         # This file
└── README.md
```

---

## Project context for task mode

> `/task` reads this section to orient itself when working on an existing project.
> Fill in everything that applies. Delete lines that don't.

- **Entry points**: [e.g. "Backend starts in `backend/app/main.py`. Frontend starts in `frontend/src/app/page.tsx`."]
- **Key services/modules**: [e.g. "Auth lives in `services/auth.py`. All LLM calls go through `services/llm.py`."]
- **Data layer**: [e.g. "PostgreSQL via SQLAlchemy. Migrations in `alembic/versions/`. Never run raw SQL."]
- **Environment setup**: [e.g. "Copy `.env.example` → `.env`. Run `docker compose up` to start everything."]
- **Test command**: [e.g. "`pytest backend/` for Python, `npm test` for frontend."]
- **Common gotchas**: [e.g. "Frontend runs on port 3001, not 3000. The Docker volume for Postgres is named — don't delete it."]
- **Off-limits at all times**: [e.g. "`data/approved/` is read-only. Never modify `.husky/`."]

---

## Key conventions

Current, explicitly approved project operating rules and preferences live in
`.rig/memory/PROJECT_CONVENTIONS.md`. Read it at the start of every session.
Never add, remove, or materially change a convention without explicit user
approval, and do not infer preferences from observed behavior or one-off requests.

---

## Base branch

The repository's main integration branch. All PRs target this branch.
`/post-merge`, `/rig-ship`, and related workflows read this field.

```
base-branch: [BASE_BRANCH]
```

---

## Git workflow convention

Controls how `/post-merge` handles housekeeping commits (PROGRESS.md updates,
task file moves) that were not included in the PR itself.

```
housekeeping: direct-push
```

| Value | Behaviour |
|---|---|
| `direct-push` | Commits and pushes directly to `[BASE_BRANCH]`. No branch, no PR. Default for solo projects. **Scope:** `chore(memory)`, `chore(release)`, `chore(post-merge)`, `docs(...)` only. Code-change types (`feat`, `fix`, `refactor`, `test`, `perf`, `devops`) are blocked even with this setting — they must go through a PR. |
| `pr-required` | Creates a short-lived `chore/post-merge-[N]` branch and opens a PR. Use when your team requires PRs for all changes. |

Change this value to match your project's branching convention.

> **Upgrade commits are not covered by this setting.** When `/rig-upgrade` modifies
> more than 3 files (hooks, commands, process files), use a `chore/rig-upgrade-vX.Y.Z`
> branch and PR regardless of this value. `housekeeping: direct-push` applies to
> memory and post-merge commits only — not to Rig upgrades.

---

## Project settings

These fields are read by Claude commands, Codex skills, and shared workflow files. Set them once and every
future session inherits them — no need to re-state preferences in chat.

```
issue-tracking: github
```

| Value | Behaviour |
|---|---|
| `github` | GitHub issues required. `/task` blocks until an issue number is provided (or drafts one and files it after exact approval when `issue-creator: agent`). Ref format: `[#N]`. `gh` CLI used for all PR/issue operations. |
| Any other tracker name | User provides an existing reference. Commits use `[reference]`. Optional `issue-ref-pattern:` validates the reference; without it, any nonempty bracketed reference is accepted. The agent does not create tickets in that tracker. |
| `none` | No issue tracker. Issue requirement is skipped in `/task`, `/rig-ship`, and commit messages. Use for personal projects or prototypes. |

`linear`, `trello`, and `gus` remain built-in reference presets for existing
projects: `ENG-123`, `trello:CARD-ID`, and `W-1234567` respectively. Any
tracker can override the preset with `issue-ref-pattern:` and
`issue-ref-example:`. The pattern is an extended regular expression matched
against the complete reference without brackets; the example appears in
instructions and error messages. Replace the existing `issue-tracking:` line
and uncomment the optional keys if you use this example:

```
# issue-tracking: jira
# issue-ref-pattern: '[A-Z]+-[0-9]+'
# issue-ref-example: APP-123
```

```
issue-creator: user
```

| Value | Behaviour |
|---|---|
| `user` | (Default) Agent blocks and waits for the user to provide a ticket number before starting any task. |
| `agent` | Agent drafts the GitHub issue, shows its exact title, body, labels, and target repository, and files it only after the user approves that individual write. It proceeds after the issue number exists. **Only applies when `issue-tracking: github`.** For all other trackers, `user` behavior is always used regardless of this setting. |

```
secret-scanner: gitleaks
```

| Value | Behaviour |
|---|---|
| `gitleaks` | `gitleaks --staged` runs on every commit. Requires `gitleaks` to be installed. |
| `none` | Secret scanning disabled. Remove or comment out the gitleaks block in `.husky/pre-commit`. |

```
commit-cleanup: yes
```

| Value | Behaviour |
|---|---|
| `yes` | `commit-msg` removes known tool footers before the commit. If a client adds one later, `post-commit` warns; `RIG_POST_COMMIT_AUTO_AMEND=1` permits amendment of ordinary unsigned commits. Signed and replayed commits keep late footers for manual cleanup. |
| `no` | Footers are kept. Comment out or remove `.husky/commit-msg` and `.husky/post-commit` to disable cleanup. |

```
# transcript-retention-days: 14
```

Optional retention preference, commented out by default. The wrap workflow
currently skips automatic transcript pruning even when this is a positive
integer: Claude project directory names can collide, and Codex has no documented
project-scoped session directory. Pruning can resume only after a trustworthy
project ownership check is available.

```
rig-gaps-push-target:
```

```
# test-command: bats tests/
```

Optional. Command to run the project's test suite. Read by `/rig-review` to validate changes before
reviewing the diff. Set this once and every future `/rig-review` run uses it automatically.

```
# lint-command: bash -n install.sh
```

Optional. Command to run the linter or syntax checker. Read by `/rig-review` alongside `test-command`.

```
# testing: playwright
```

Optional. If set to `playwright`, `/rig-review` runs `npx playwright test` as an additional
validation step and includes the result in the review report.

```
# staging-url:
# prod-url:
```

Optional. Included in `/rig-review` reports when set — links review findings to the
environment under test.

Optional. Absolute path to a `RIG_GAPS.md` file in The Rig's own repo on this machine.
When set, `/rig-gaps --push` appends unsubmitted gap entries directly to that file
instead of requiring manual copy-paste. Only useful for developers who maintain The Rig
(or a fork) on the same machine.

Example: `rig-gaps-push-target: /Users/you/.rig/projects/the-rig/memory/RIG_GAPS.md`

Leave blank (or omit the line) if you don't have The Rig repo on this machine.

**Contribute mode** — opt-in GitHub issue submission via `/rig-gaps --submit`:

```bash
# Enable once to allow /rig-gaps --submit to post public GitHub issues:
REPO=$(git rev-parse --show-toplevel)
RIG_DIR=$(python3 "$REPO/bin/rig-path.py" "$REPO") || exit 1
touch "$RIG_DIR/memory/.rig-contribute-enabled"
```

When this sentinel file exists, `/rig-gaps --submit` can create issues in
`laudtetteh/the-rig` via the `gh` CLI. Each entry is reviewed and confirmed
individually before submission. Requires `gh auth login` with public repo access.
The file is gitignored — opt-in is per-machine, not per-repo.

---

## Off-limits — never touch without explicit instruction

- `.husky/` — git hooks are stable; do not modify
- `.claude/worktrees/` — Claude Code-specific internal path; never edit or write here
- `.github/` — issue and PR templates are set; do not modify
- `[any other protected path]` — [reason]

---

## How to run locally

```bash
# Full stack
docker compose up

# Backend only
[command]

# Frontend only
[command]

# Run tests
[command]
```

---

## Context files — load at session start

> **Hook-enforced:** The `SessionStart` hook automatically injects `CONTEXT_SNAPSHOT.md`
> and any pending flag warnings before the first turn. The instructions below are a
> fallback for sessions where the hook is absent or fails.

When starting a new session, read in this order:

1. `.rig/memory/PROJECT_CONVENTIONS.md` — current, explicitly user-approved
   operating rules and preferences. Always load this file; it is not replaced by
   the context snapshot.
2. `.rig/memory/CONTEXT_SNAPSHOT.md` — **if this exists, it is sufficient for orientation.
   Stop here unless the task requires deeper history.**
3. `.rig/memory/PROGRESS.md` — only if `CONTEXT_SNAPSHOT.md` is absent or more than one
   session old. Load the most recent entries only (last 20 `##` sections).
4. `.rig/memory/ERRORS.md` — known pitfalls
5. `.rig/memory/DECISIONS.md` — consequential decisions, alternatives, rationale,
   and consequences (skim only)
6. `.rig/tasks/active/` — current in-flight task(s)

**After reading context, check for pending housekeeping flags:**

> The `UserPromptSubmit` hook injects these warnings automatically on every prompt.
> Check manually only if the hook is absent or the session started without one.

- If `.rig/memory/.wrap-needed` exists: say exactly —
  > "⚠️ The last session ended without running `/wrap`. CONTEXT_SNAPSHOT.md may be
  > stale and PROGRESS.md has unexpanded entries. Run `/wrap` now to capture session
  > state before we start new work — or say 'skip wrap' to proceed anyway."
  Wait for the user's response before continuing.

- If `.rig/memory/.post-merge-pending` exists: say exactly —
  > "⚠️ A merge landed since `/post-merge` was last run. Memory may not reflect the
  > merged state. Run `/post-merge` now — or say 'skip post-merge' to proceed anyway."
  Wait for the user's response before continuing.

> **External .rig/ note:** if `.rigpath` exists at the project root, all `.rig/`
> paths above resolve to the external directory it points to. The installer
> updates these paths automatically when the external tracking option is chosen.

---

## Feature documentation

End-to-end traces for business-critical features. Feature docs live in the
project repository's `docs/features/` directory in every tracking mode,
including stealth and external installs. The `/doc-feature`, `/feature-context`,
and `/refresh-feature-doc` commands resolve this path from the repository root.

- **Before touching code** that overlaps with a documented feature, run
  `/feature-context <feature>` to load the doc into context
- **After any PR** that changes a documented feature's logic, run
  `/refresh-feature-doc <feature>` to keep the doc current
- **To document a new feature**, run `/doc-feature <feature name>` immediately
  after researching it — capture the knowledge while it's fresh

@docs/features/README.md

---

## Work-mode routing

Use `.rig/processes/WORK_MODES.md` as the canonical lifecycle, state,
transition, approval, and resume contract. Route intent to the smallest mode:

- New project with no established backlog: `/kickoff` (project mode).
- Define or configure one unit of work: `/task` (task intake).
- Execute one task or a simple ordered queue: `/rig-run` (task mode).
- Coordinate multiple tasks with conflicts/dependencies: `/sprint` (sprint mode).

Supported compositions are project -> task, project -> sprint, task -> sprint,
and sprint -> isolated task. A task embedded in `/rig-run` or `/sprint` keeps the
same task card, operating mode, checkpoint, and ship gate. Never treat a mode
transition as execution approval; checkpoint the source artifact and obtain the
receiving mode's required approval.

---

## Imported rules

@.rig/rules/coding-standards.md
@.rig/rules/git-conventions.md
@.rig/rules/security.md
@.rig/rules/verification.md
