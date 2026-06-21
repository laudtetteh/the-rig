# [Project Name] — project brain

> This file is loaded automatically by Claude Code at the start of every session in this repo.
> Fill in every [PLACEHOLDER]. Delete sections that don't apply.
> Keep it lean — only things specific to this project belong here.
> Universal rules (working style, hard rules, git conventions) live in ~/.claude/CLAUDE.md.

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
│   ├── features/     # Feature docs (README.md index + one .md per feature)
│   └── [other docs]  # Architecture, decisions, PRD
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

- [Project-specific convention — e.g. "Never call the LLM API directly from a route — always go through the service layer"]
- [Project-specific convention]
- [Project-specific convention]

---

## Base branch

The repository's main integration branch. All PRs target this branch.
`/post-merge`, `/ship`, and related workflows read this field.

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

These fields are read by slash commands and workflow files. Set them once and every
future session inherits them — no need to re-state preferences in chat.

```
issue-tracking: github
```

| Value | Behaviour |
|---|---|
| `github` | GitHub issues required. `/task` blocks until issue number provided (or agent creates one if `issue-creator: agent`). Ref format: `[#N]`. `gh` CLI used for all PR/issue operations. |
| `linear` | Linear tickets required. User provides existing ticket ID (e.g. `ENG-123`). Ref format: `[ENG-123]`. Agent never creates Linear tickets. |
| `trello` | Trello cards required. User provides existing card ID. Ref format: `[trello:CARD-ID]`. Agent never creates Trello cards. |
| `gus` | GUS work items required. User provides existing item ID (e.g. `W-1234567`). Ref format: `[W-1234567]`. Agent never creates GUS items. |
| `none` | No issue tracker. Issue requirement is skipped in `/task`, `/ship`, and commit messages. Use for personal projects or prototypes. |

```
issue-creator: user
```

| Value | Behaviour |
|---|---|
| `user` | (Default) Agent blocks and waits for the user to provide a ticket number before starting any task. |
| `agent` | Agent creates the GitHub issue itself using the task description, then proceeds immediately. **Only applies when `issue-tracking: github`.** For all other trackers, `user` behavior is always used regardless of this setting. |

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
| `yes` | Auto-injected tool footers (`Co-Authored-By: Claude`, `Made-with-Claude`, etc.) are stripped from commit messages by the `commit-msg` and `post-commit` hooks. |
| `no` | Footers are kept. Comment out or remove `.husky/commit-msg` and `.husky/post-commit` to disable the stripping. |

```
# transcript-retention-days: 14
```

Optional. When set to a positive integer, `/wrap` prunes JSONL transcript files in
`~/.claude/projects/` older than this many days. Prevents `/tmp` or disk from filling up
after long-running projects. Commented out by default — uncomment and set a value to enable.

```
rig-gaps-push-target:
```

Optional. Absolute path to a `RIG_GAPS.md` file in The Rig's own repo on this machine.
When set, `/rig-gaps --push` appends unsubmitted gap entries directly to that file
instead of requiring manual copy-paste. Only useful for developers who maintain The Rig
(or a fork) on the same machine.

Example: `rig-gaps-push-target: /Users/you/.rig/projects/the-rig/memory/RIG_GAPS.md`

Leave blank (or omit the line) if you don't have The Rig repo on this machine.

**Contribute mode** — opt-in GitHub issue submission via `/rig-gaps --submit`:

```bash
# Enable once to allow /rig-gaps --submit to post public GitHub issues:
touch .rig/memory/.rig-contribute-enabled
```

When this sentinel file exists, `/rig-gaps --submit` can create issues in
`laudtetteh/the-rig` via the `gh` CLI. Each entry is reviewed and confirmed
individually before submission. Requires `gh auth login` with public repo access.
The file is gitignored — opt-in is per-machine, not per-repo.

---

## Off-limits — never touch without explicit instruction

- `.husky/` — git hooks are stable; do not modify
- `.claude/worktrees/` — Claude Code internal; never edit or write here
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

1. `.rig/memory/CONTEXT_SNAPSHOT.md` — **if this exists, it is sufficient for orientation.
   Stop here unless the task requires deeper history.**
2. `.rig/memory/PROGRESS.md` — only if `CONTEXT_SNAPSHOT.md` is absent or more than one
   session old. Load the most recent entries only (last 20 `##` sections).
3. `.rig/memory/ERRORS.md` — known pitfalls
4. `.rig/memory/DECISIONS.md` — architectural and process decisions (skim only)
5. `.rig/tasks/active/` — current in-flight task(s)

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

End-to-end traces for business-critical features. Feature docs live in
`$RIG_DIR/docs/features/` — for repo-tracked projects this is `docs/features/`;
for stealth/external projects it resolves to the external `.rig/` directory via
`.rigpath`. The `/doc-feature`, `/refresh-feature-doc`, and `/feature-doc` commands
all resolve this path automatically.

- **Before touching code** that overlaps with a documented feature, run
  `/feature-context <feature>` to load the doc into context
- **After any PR** that changes a documented feature's logic, run
  `/refresh-feature-doc <feature>` to keep the doc current
- **To document a new feature**, run `/doc-feature <feature name>` immediately
  after researching it — capture the knowledge while it's fresh

@docs/features/README.md

---

## Imported rules

@.rig/rules/coding-standards.md
@.rig/rules/git-conventions.md
@.rig/rules/security.md
@.rig/rules/verification.md
