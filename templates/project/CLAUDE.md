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
├── docs/             # Architecture, decisions, PRD
├── memory/           # PROGRESS.md, ERRORS.md, CONTEXT_SNAPSHOT.md (gitignored)
├── processes/        # Agent workflow files
├── rules/            # Coding standards, git conventions, security, verification
├── tasks/            # active/, backlog/, done/
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

When starting a new session, read in this order:

1. `memory/CONTEXT_SNAPSHOT.md` — current state (fastest orientation)
2. `memory/PROGRESS.md` — full build history
3. `memory/ERRORS.md` — known pitfalls
4. `tasks/active/` — current in-flight task(s)

If `CONTEXT_SNAPSHOT.md` does not exist, fall back to `PROGRESS.md` as primary orientation.

---

## Imported rules

@rules/coding-standards.md
@rules/git-conventions.md
@rules/security.md
@rules/verification.md
