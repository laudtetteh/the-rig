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
| `/run` | Work through the task backlog. Surveys ready tasks, proposes an execution order, and drives them to completion in the configured autonomy mode. Accepts an optional `[task-slug]` to run one specific task. Surfaces the operating mode wizard if `## Operating mode` is absent from the task file. |
| `/ship` | Commit and close a task. Sequential hard gate: task ID → issue → labels → branch → pre-commit cleanup → checklist → testing pause → commit message → commit → post-housekeeping → PR. |
| `/sprint` | Execute a batch of tasks with conflict detection and wave-based ordering to minimize merge friction. Accepts `[slug ...]` to target specific tasks or `--issues #N ...` to resolve by GitHub issue number. Use `/run` for simple sequential execution without conflict analysis. |

## Session management

| Command | What it does |
|---|---|
| `/wrap` | End a session. Writes `CONTEXT_SNAPSHOT.md`, expands `PROGRESS.md` stubs, captures in-flight task state, names the session. |
| `/post-merge` | Post-merge housekeeping. Run immediately after a PR lands: pulls main, logs the PR to `PROGRESS.md`, moves the task file to done, refreshes `CONTEXT_SNAPSHOT.md`, checks feature doc freshness, and surfaces what's next. |
| `/status` | Project state dashboard. Shows current branch, active tasks, backlog count, and recent `PROGRESS.md` entries. |
| `/session-name` | Derive and set a session name from work completed so far. Uses the same tiered format as `/wrap` and `/post-merge` but callable at any time without triggering a full cycle. |

## Research and documentation

| Command | What it does |
|---|---|
| `/recon <topic>` | Research how a feature or system was built. Sweeps internal memory (`DECISIONS.md`, `ERRORS.md`, `PROGRESS.md`), then PR history, commit messages, and live code; synthesizes a timeline and current state. `--depth shallow` for a quick pass, `--depth full` for exhaustive research. |
| `/doc-feature <name>` | Write a new feature doc. Checks for an existing doc first, then researches and writes to `docs/features/[name].md`. Prompts for a name if omitted. |
| `/refresh-feature-doc <name>` | Update an existing feature doc after a PR changes its logic. Accepts a feature name or doc path; prompts if omitted. |
| `/feature-context <name>` | Load an existing feature doc into context before touching related code. Lists available docs if no argument given. |
| `/doc-list` | Show the docs index (`docs/INDEX.md`) without loading full doc files. |

## Debugging

| Command | What it does |
|---|---|
| `/debug` | Structured diagnosis. Hypothesis → reproduce → isolate → fix → log in `ERRORS.md`. No code touched until the bug is reproduced. |

## Release

| Command | What it does |
|---|---|
| `/pre-release-review` | Full stability review before cutting a release. Covers regressions, test coverage, security, docs accuracy, maintainability, edge cases, and version bump readiness. Outputs a scored report with a SHIP / HOLD recommendation. |

## Project setup

| Command | What it does |
|---|---|
| `/kickoff` | Bootstrap a brand new project from `PROJECT_BRIEF.md`. Run once on a fresh repo. |
| `/rig-install` | Guided first-time install wizard. Run from inside the Rig repo to install onto a new project. Asks three questions (scope, path, tracking mode), shows the exact command, and verifies the install. For upgrades of existing installs, use `/rig-upgrade`. |

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
