# The Rig

**An opinionated agentic coding system for Claude Code.**

The Rig wraps Claude Code with structured memory, enforced workflows, automated safety hooks, and a commit history discipline — so AI-assisted development stays consistent across sessions, projects, and months.

Built and refined across 100+ pull requests on a real production project.

---

## The problem it solves

Claude Code is powerful but stateless. Without structure, every session:

- Starts cold — repeats decisions already made, re-asks questions already answered
- Drifts — different conventions each session, silently violated rules
- Causes invisible damage — writes to protected files, commits without scanning for secrets, amends history in hidden worktrees
- Leaves no trail — no record of why things were built the way they were

The Rig solves all of this. Not through better prompts — through enforced structure.

---

## Architecture

The Rig has two layers that load in sequence at every session start:

```
┌─────────────────────────────────────────────────────────────────┐
│  GLOBAL LAYER  (~/.claude/)                                     │
│  Installed once. Applies to every project on the machine.       │
│                                                                 │
│  CLAUDE.md          ← identity, hard rules, working style       │
│  skills/            ← reusable skill scripts (5 included)       │
│  ~/.your-ai-contexts/PROFILE.md  ← personal/professional context│
└────────────────────────────┬────────────────────────────────────┘
                             │ loaded first at every session
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  PROJECT LAYER  (per-repo, version-controlled)                  │
│  Scaffolded per project. Defines project-specific behaviour.    │
│                                                                 │
│  CLAUDE.md          ← project identity, stack, conventions      │
│  processes/         ← new-task, ship, debug, post-merge flows   │
│  rules/             ← coding standards, git, security, verify   │
│  memory/            ← PROGRESS, ERRORS, CONTEXT_SNAPSHOT        │
│  tasks/             ← active / backlog / done lifecycle         │
│  .claude/           ← hook wiring + slash commands              │
│  .husky/            ← secret scanning + AI trailer stripping    │
│  .github/           ← PR template + issue templates             │
└─────────────────────────────────────────────────────────────────┘
```

---

## What's included

| Component | Location | What it does |
|---|---|---|
| Global identity | `templates/global/CLAUDE.md` | Hard rules, working style, memory discipline — loads at every session |
| Personal profile | `templates/global/PROFILE.md.example` | Your professional context — the agent reads it so you never re-explain yourself |
| Skills (5) | `templates/global/skills/` | Reusable prompt scripts for debug, review, refactor, tests, explain |
| Project brain | `templates/project/CLAUDE.md` | Project-specific identity, stack, conventions, off-limits paths |
| Processes (4) | `templates/project/processes/` | Step-by-step workflows: new-task, ship, debug, post-merge |
| Rules (4) | `templates/project/rules/` | Coding standards, git conventions, security rules, verification protocol |
| Memory system | `templates/project/memory/` | PROGRESS log, ERRORS log, CONTEXT_SNAPSHOT (session state) |
| Task lifecycle | `templates/project/tasks/` | Structured task files through backlog → active → done |
| Claude Code hooks | `templates/project/.claude/` | Pre/post-tool enforcement + 8 slash commands |
| Git hooks | `templates/project/.husky/` | Secret scanning (gitleaks) + AI attribution trailer stripping |
| GitHub templates | `templates/project/.github/` | PR template + 3 issue templates |
| Installer | `install.sh` | Interactive setup script — handles both layers |

---

## Quickstart

### Step 1 — Install The Rig once (per machine)

```bash
# Clone to a permanent tools location — do this once, not per project
# HTTPS:
git clone https://github.com/laudtetteh/the-rig.git ~/tools/the-rig
# SSH:
git clone git@github.com:laudtetteh/the-rig.git ~/tools/the-rig

cd ~/tools/the-rig
./install.sh --global-only

# Fill in your personal profile
$EDITOR ~/.your-ai-contexts/PROFILE.md
```

This installs the global layer (`~/.claude/CLAUDE.md` + skills) once. Every project
on your machine shares it.

---

### Step 2 — Scaffold a new project

```bash
# Create your project directory (name it whatever you want)
mkdir ~/code/my-project && cd ~/code/my-project
git init

# Run the installer from your permanent Rig location
~/tools/the-rig/install.sh --project-only
# When prompted, point it at ~/code/my-project

# Then open Claude Code in your project and run /kickoff
# /kickoff reads PROJECT_BRIEF.md, confirms the project shape,
# and scaffolds CLAUDE.md + task backlog + GitHub issues in one pass.
```

The Rig stays in `~/tools/the-rig/`. Your project is clean.

---

### Dropping The Rig into an existing project

```bash
~/tools/the-rig/install.sh --project-only
# Point it at your existing project directory
# Choose collision strategy: Skip (safest) or Merge (.claude/settings.json only)
```

---

### Upgrading

```bash
cd ~/tools/the-rig && git pull
./install.sh --project-only
# Choose Merge — adds new files, preserves your customizations
```

---

## How it works at session start

When you open Claude Code in a project using The Rig, the agent automatically reads (in order):

1. `~/.claude/CLAUDE.md` — who it is and how to behave
2. `~/.your-ai-contexts/PROFILE.md` — who you are
3. `./CLAUDE.md` — what this project is
4. `./memory/PROGRESS.md` — where the project stands
5. `./memory/ERRORS.md` — what to avoid
6. `./tasks/active/` — what's currently in flight

No re-briefing. No repeating context. Every session picks up exactly where the last one left off.

---

## The command set

**Start a project**
```
/kickoff      →  reads PROJECT_BRIEF.md, scaffolds CLAUDE.md + task backlog + GitHub issues
```

**Daily work**
```
/task         →  intake wizard: define the task + configure autonomy, check-ins, and risk
/run          →  execute the backlog; respects per-task operating mode; chains at High autonomy
/run [slug]   →  run a single specific task
```

**Ship and debug**
```
/ship         →  pre-ship checklist, commit, open PR
/debug        →  hypothesis-first diagnosis, mandatory ERRORS.md entry
```

**Governance and housekeeping**
```
/propose      →  submit a change to governance files for human approval before anything is touched
/wrap         →  write CONTEXT_SNAPSHOT, ensure memory is current before closing the session
```

---

## What the hooks enforce

| Hook | Trigger | What it prevents |
|---|---|---|
| `pre-tool.sh` | Before every Claude Code tool call | Writes to protected paths (`.env.production`, etc.) |
| `post-tool.sh` | After every Claude Code tool call | PROGRESS.md being skipped after a commit |
| `pre-commit` | Before every git commit | Secrets reaching the repository |
| `commit-msg` + `post-commit` | On every git commit | AI attribution trailers (`Co-Authored-By: Claude`, etc.) in history |

---

## Requirements

| Requirement | Notes |
|---|---|
| [Claude Code](https://docs.anthropic.com/claude-code) | The AI coding CLI this system wraps |
| bash 3.2+ | For `install.sh` and hook scripts |
| git | For hooks and version control |
| [gitleaks](https://github.com/gitleaks/gitleaks) | Secret scanning (`brew install gitleaks`) |
| npm / npx | For Husky initialization (optional if not using Node projects) |

---

## Documentation

- [How it works](docs/how-it-works.md) — architecture deep-dive with diagrams
- [Key decisions](docs/decisions.md) — design rationale and tradeoffs
- [Lessons learned](docs/lessons-learned.md) — 10 documented pitfalls from the pilot
- [Customizing](docs/customizing.md) — adapting The Rig for your stack

---

## Origin

The Rig was designed and refined entirely within a single project — [LaudBot](https://github.com/laudtetteh/laudbot), an AI-powered interactive resume. It grew organically as each session revealed a new failure mode. Every component exists because something went wrong without it.

The LaudBot repo history — 100+ PRs, clean conventional commits, linked issues, documented architecture — is the proof of concept.

---

## License

MIT — see [LICENSE](LICENSE).
