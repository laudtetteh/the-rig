# Command: /rig-install

Guides a user through a first-time install of The Rig onto a project.
Run this command when working inside the Rig repo itself.

For raw flag reference and all scenario commands, see `docs/agent-install.md`.

---

## What this does

1. Asks the user three questions to identify their scenario
2. Emits the exact non-interactive install command for that scenario
3. Runs the command after confirmation
4. Verifies the install succeeded

---

## Step 1 — Identify scenario

Ask the user the following. Collect all answers before proceeding.

**Q1: What are you installing?**
- **A** — Global layer only (first time on this machine — installs `~/.claude/CLAUDE.md` and skills)
- **B** — Project layer only (Rig already installed globally on this machine)
- **C** — Both layers at once (brand new machine + new project)

**Q2: What is the absolute path to your project?** *(skip if A)*

Example: `/Users/you/code/my-project`

**Q3: How should `.rig/` be tracked?** *(skip if A)*
- **1 — repo**: committed to git — visible to all contributors
- **2 — local**: gitignored — on disk only, not committed
- **3 — stealth**: zero traces in git — `.rig/` stored at `~/.rig/projects/<name>/`
- **4 — external**: outside the repo at a path you specify

If unsure: use **stealth** for shared repos, **repo** for solo projects.

---

## Step 2 — Confirm and run

Based on the answers, construct the command from the table below and show it to the user before running.

| Scenario | Command |
|---|---|
| A — global only | `./install.sh --global-only --strategy merge` |
| B + tracking=repo | `./install.sh --project-only --target <path> --tracking repo --strategy merge --project-name "<name>"` |
| B + tracking=local | `./install.sh --project-only --target <path> --tracking local --strategy merge --project-name "<name>"` |
| B + tracking=stealth | `./install.sh --project-only --target <path> --tracking stealth --strategy merge --project-name "<name>"` |
| B + tracking=external | `./install.sh --project-only --target <path> --tracking external --rig-dir <rig-path> --strategy merge --project-name "<name>"` |
| C — both layers | `./install.sh --target <path> --tracking <mode> --strategy merge --project-name "<name>"` |

Derive `<name>` from the project directory name if the user hasn't specified one.

Say to the user:

> "I'll run: `[command]`
>
> Say **go** to proceed, or adjust any value."

Wait for confirmation before running.

---

## Step 3 — Run the install

```bash
cd /path/to/the-rig   # must run from the Rig repo root
[command from Step 2]
```

Capture the output. If the exit code is non-zero, show the error and stop.

---

## Step 4 — Post-install verification

After a successful run, verify:

```bash
# Check hooks exist and are executable
ls -la <project-path>/.claude/hooks/pre-tool.sh
ls -la <project-path>/.husky/pre-commit

# Check settings.json is wired
grep "pre-tool" <project-path>/.claude/settings.json
```

For stealth or external installs, also check:

```bash
cat <project-path>/.rigpath
git -C <project-path> status   # should show no Rig files
```

Report the result:

> "Install complete. Hooks wired, settings.json wired, [.rigpath confirmed / .rig/ committed].
>
> **Next steps:**
> 1. If this was a global-only install, fill in `~/.your-ai-contexts/PROFILE.md` with your professional context.
> 2. If this was a project install, open Claude Code in the project and run `/kickoff` to scaffold `CLAUDE.md` and the task backlog."

---

## Notes

- This command must be run from inside the Rig repo (`~/tools/the-rig/` or wherever it is cloned). `install.sh` is the entry point — it is not installed into projects.
- For upgrades of existing installs, use `/rig-upgrade` instead.
- For the full flag reference and all scenario variants, see `docs/agent-install.md`.
