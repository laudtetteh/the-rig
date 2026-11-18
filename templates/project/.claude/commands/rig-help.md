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
| `/ship` | Commit and close a task. Sequential hard gate: task ID → issue → labels → branch → pre-commit cleanup → checklist → dependency impact → testing pause → commit message → commit → post-housekeeping → PR → final merge-boundary metadata review → merge verification when authorized. |
| `/sprint` | Execute a batch of tasks with conflict detection and wave-based ordering to minimize merge friction. Accepts `[slug ...]` to target specific tasks or `--issues #N ...` to resolve by GitHub issue number. Use `/run` for simple sequential execution without conflict analysis. |

## Session management

| Command | What it does |
|---|---|
| `/wrap` | End a session. Writes `CONTEXT_SNAPSHOT.md`, expands `PROGRESS.md` stubs, captures in-flight task state, names the session. Use `/wrap --checkpoint` to save memory and handoffs while the exact session remains active; a later ordinary wrap still finalizes. |
| `/handoff-checklist` | Consent-gated wrap-and-handoff routine for large or costly sessions. Asks before doing any checklist work. |
| `/post-merge` | Post-merge housekeeping. Fetches the base branch and verifies each exact merge SHA before logging the PR to `PROGRESS.md`, moving the task file to done, refreshing `CONTEXT_SNAPSHOT.md`, checking feature doc freshness, and surfacing what's next. A clean base checkout is fast-forwarded only when tracked housekeeping needs it. |
| `/status` | Project state dashboard. Shows current branch, active tasks, backlog count, and recent `PROGRESS.md` entries. |
| `/session-name` | Derive and set a session name from work completed so far. Uses the same tiered format as `/wrap` and `/post-merge` but callable at any time without triggering a full cycle. |
| `bin/rig session index` | Search Rig session records across the current project, immediate `~/code/` projects, and external `~/.rig/projects/` directories. Use `--root PROJECT` for another location. The index is read-only, reports coverage and ambiguity, and never scans provider transcripts. |

### Provider-native aids for concurrent conversations

These controls help you distinguish or find provider conversations. Color and provider titles do not directly name or clear Rig records; resuming a conversation can still trigger Rig lifecycle hooks that bind or create a session anchor. Use `/session-name` to name the Rig record, and `/wrap` or `/post-merge` to complete its obligations.

| Provider | When useful | Native control |
|---|---|---|
| Claude Code | Several terminal conversations look alike | `/color blue` changes this conversation's prompt-bar color; `/rename <label>` changes its provider title. |
| Codex CLI | Return to a saved conversation | `codex resume` opens the picker, `codex resume --all` includes other working directories, and `codex resume --last` skips the picker. |

Check the installed CLI's help if a native control is unavailable. See the [Claude Code command reference](https://code.claude.com/docs/en/commands) and [Codex CLI guide](https://learn.chatgpt.com/docs/codex/cli).

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
| `/code-review` | Diff-focused review of the current branch. Runs tests + lint (from `test-command:`/`lint-command:` in CLAUDE.md), analyses the diff by category (logic, security, coverage, dependency impact, style), and produces a structured LGTM/HOLD report. Playwright opt-in via `testing: playwright`. |

## Release

| Command | What it does |
|---|---|
| `/pre-release-review` | _(release-cycle projects)_ Full stability review before cutting a release. Covers regressions, test coverage, security, docs accuracy, maintainability, edge cases, and version bump readiness. Outputs a scored report with a SHIP / HOLD recommendation. |

## Project setup

| Command | What it does |
|---|---|
| `/kickoff` | _(new projects only)_ Bootstrap a brand new project from `PROJECT_BRIEF.md`. Run once at project creation. |

## Rig maintenance

| Command | What it does | Key flags |
|---|---|---|
| `/rig-upgrade` | Upgrade The Rig to the latest version. | `--version` (print versions only, no upgrade), `--scope=project\|global\|both`, `--mode=agent\|classic` (skip the mode prompt) |
| `/rig-propose` | _(opt-in: `--contribute`)_ Propose a change to Rig governance files (hooks, processes, rules, CLAUDE.md). Writes a diff for human review — never applies it directly. | — |
| `/rig-gaps` | _(opt-in: `--contribute`)_ Log and submit workflow friction observed during a task. | `--push` (append to local Rig repo), `--submit` (create GitHub issue) |
| `/rig-help` | This command. | — |

---

## Installer opt-in flags

Some features are not installed by default. Pass these flags to `install.sh` (or `/rig-upgrade`) to enable them:

| Flag | What it installs |
|---|---|
| `--feature-docs` | `/doc-feature`, `/doc-list`, `/feature-context`, `/refresh-feature-doc`, `docs/INDEX.md`, and `docs/features/` — for projects that maintain end-to-end feature traces |
| `--subagents` | `subagent-start.sh` hook + `SubagentStart` event wiring in `settings.json` — for projects using multi-agent Claude Code workflows |
| `--contribute` | `/rig-gaps` and `/rig-propose` — for developers who maintain The Rig or a fork |

These flags are preserved across upgrades: once a feature is installed, it is auto-detected and retained on future upgrade runs without re-passing the flag.

---

## Permission management

For Claude Code, the project wiring and bundled Claude Code commands provide four permission controls:

| Mechanism | What it does | How to configure |
|---|---|---|
| `permission-request.sh` | Runtime hook — intercepts unapproved tool requests; auto-approves read-only patterns and Markdown notes under `$RIG_DIR/memory`, `tasks`, and `docs` | Installed automatically; edit to add custom auto-approvals |
| `/permissions` | Claude Code built-in — pre-approves or pre-denies specific tool patterns before a session starts | Run `/permissions` in Claude Code |
| `settings.json` `allow`/`deny` | Persistent per-project rules loaded at every session; no prompt for matched patterns | Edit `.claude/settings.json` directly |
| `/fewer-permission-prompts` | Claude Code bundled skill (Claude only) — scans transcripts for frequent patterns and bulk-adds them to `settings.json` `allow` | Run in Claude Code; this slash skill is unavailable in Codex |

**Baseline deny patterns** (shipped in `settings.json`): `rm -rf *`, `git push --force*`, `git push -f*`. Add project-specific shell-command patterns to the `deny` array as needed.

---

## Notes

- This table is maintained manually; update it when a new command is added or flags change
- For full command details, read the relevant `.claude/commands/[name].md` file
- For Rig storage, identity, and manifest terms, see the [glossary](https://github.com/laudtetteh/the-rig/blob/main/docs/glossary.md)
