# Command: /rig-help

Print a reference table of all Rig slash commands with descriptions and key flags.

## Usage

```
/rig-help
```

No arguments. Output the table below directly — do not read individual command files to build it.

---

## Task management

| Command | What it does |
|---|---|
| `/task` | Start a new unit of work. Runs the intake wizard: goal, area, constraints, issue number, operating mode (autonomy / check-ins / risk). Creates a task file in `.rig/tasks/`. |
| `/run` | Continue an active task. Reads the task file, confirms operating mode, executes the next step. Surfaces the inline wizard if `## Operating mode` is absent. |
| `/ship` | Commit and close a task. Sequential gate: task ID → issue → labels → branch → pre-commit cleanup → checklist → testing pause → commit message → commit → post-housekeeping → PR. |
| `/sprint` | Plan the next sprint. Reviews backlog, active tasks, and recent velocity; proposes a prioritized work order. |

## Session management

| Command | What it does |
|---|---|
| `/wrap` | End a session. Writes `CONTEXT_SNAPSHOT.md`, expands `PROGRESS.md` stubs, captures in-flight task state, names the session. |
| `/status` | Project state dashboard. Shows current branch, active tasks, backlog count, and recent `PROGRESS.md` entries. |

## Research and documentation

| Command | What it does |
|---|---|
| `/recon` | Research how a feature works. Checks internal docs first (`DECISIONS.md`, `ERRORS.md`, `PROGRESS.md`), then reads code. Produces an end-to-end trace. |
| `/doc-feature` | Write a new feature doc. Checks for an existing doc first, then researches and writes to `docs/features/[name].md`. |
| `/refresh-feature-doc` | Update an existing feature doc after a PR changes its logic. |
| `/feature-context` | Load an existing feature doc into context before touching related code. |
| `/doc-list` | Show the docs index (`docs/INDEX.md`) without loading full doc files. |

## Debugging

| Command | What it does |
|---|---|
| `/debug` | Structured diagnosis. Hypothesis → reproduce → isolate → fix → log in `ERRORS.md`. No code touched until the bug is reproduced. |

## Project setup

| Command | What it does |
|---|---|
| `/kickoff` | Bootstrap a brand new project from `PROJECT_BRIEF.md`. Run once on a fresh repo. |

## Rig maintenance

| Command | What it does | Key flags |
|---|---|---|
| `/rig-upgrade` | Upgrade The Rig to the latest version. | `--version` (print versions only, no upgrade), `--scope=project\|global\|both` |
| `/rig-propose` | Propose a change to Rig governance files (hooks, processes, rules, CLAUDE.md). Writes a diff for human review — never applies it directly. | — |
| `/rig-gaps` | Log and submit workflow friction observed during a task. | `--push` (append to local Rig repo), `--submit` (create GitHub issue) |
| `/rig-help` | This command. | — |

---

## Notes

- `/new-feature` is deprecated — use `/task` instead
- This table is maintained manually; update it when a new command is added or flags change
- For full command details, read the relevant `.claude/commands/[name].md` file
