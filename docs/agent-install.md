# Agent install guide

How to install The Rig non-interactively — exact flag combinations for every scenario.

Use this when a Claude agent is helping a user install or upgrade The Rig.
The installer is interactive by default; the flags below bypass all prompts.

---

## Installer flags reference

| Flag | Values | What it does |
|---|---|---|
| `--global-only` | — | Install only the global layer (`~/.claude/`) |
| `--project-only` | — | Install only the project layer (target repo) |
| `--target <path>` | absolute path | Project directory to install into |
| `--tracking` | `repo` \| `local` \| `external` \| `stealth` | How `.rig/` is tracked in git |
| `--strategy` | `merge` \| `upgrade` \| `overwrite` \| `skip` | How to handle existing files |
| `--rig-dir <path>` | absolute path | Where to put `.rig/` when using external or stealth tracking |
| `--project-name <name>` | string | Project name substituted into templates |
| `--skip-git-hooks` | — | Skip writing to `.git/hooks/` (stealth + existing Husky setup) |

**Tracking modes:**

| Mode | `.rig/` location | git visibility |
|---|---|---|
| `repo` | Inside the project repo, committed | Visible to all contributors |
| `local` | Inside the project repo, gitignored | Local only |
| `external` | Outside the repo (explicit `--rig-dir`) | Invisible; `.rigpath` file points to it |
| `stealth` | Outside the repo (`~/.rig/projects/<name>/` default) | Zero traces in git |

**Strategy modes:**

| Strategy | Existing files | When to use |
|---|---|---|
| `merge` | Creates missing files, skips existing | Fresh install on a new project |
| `upgrade` | Updates Rig-owned files if unchanged; detects customizations | Upgrading an existing install |
| `overwrite` | Replaces all Rig-owned files unconditionally | Repair/reset |
| `skip` | Never overwrites anything | Safe read-only test |

---

## Scenario commands

### 1 — First-time global install (once per machine)

```bash
cd ~/tools/the-rig
./install.sh --global-only --strategy merge
# Then fill in the personal profile:
$EDITOR ~/.your-ai-contexts/PROFILE.md
```

The global layer installs `~/.claude/CLAUDE.md` and `~/.claude/skills/`. It is shared
across all projects on the machine. Run this once per machine, not per project.

---

### 2 — New project (committed `.rig/`)

For solo projects where The Rig files are committed to the repo:

```bash
cd ~/tools/the-rig
./install.sh \
  --project-only \
  --target /path/to/project \
  --tracking repo \
  --strategy merge \
  --project-name "MyProject"
```

---

### 3 — New project (local `.rig/`, gitignored)

For shared repos where you want `.rig/` on disk but invisible to git:

```bash
cd ~/tools/the-rig
./install.sh \
  --project-only \
  --target /path/to/project \
  --tracking local \
  --strategy merge \
  --project-name "MyProject"
```

---

### 4 — New project (stealth — zero git traces)

For shared repos where teammates must never see any Rig files:

```bash
cd ~/tools/the-rig
./install.sh \
  --project-only \
  --target /path/to/project \
  --tracking stealth \
  --strategy merge \
  --project-name "MyProject"
```

`.rig/` goes to `~/.rig/projects/MyProject/` by default. Use `--rig-dir` to override:

```bash
./install.sh \
  --project-only \
  --target /path/to/project \
  --tracking stealth \
  --rig-dir ~/.rig/projects/custom-name \
  --strategy merge \
  --project-name "MyProject"
```

---

### 5 — New project (external directory)

For repos where `.rig/` lives outside but isn't fully hidden:

```bash
cd ~/tools/the-rig
./install.sh \
  --project-only \
  --target /path/to/project \
  --tracking external \
  --rig-dir ~/.rig/projects/my-project \
  --strategy merge \
  --project-name "MyProject"
```

---

### 6 — Upgrade existing install

Pull the latest Rig source, then upgrade the project layer:

```bash
cd ~/tools/the-rig
git pull

./install.sh \
  --project-only \
  --target /path/to/project \
  --strategy upgrade
```

The upgrade strategy auto-updates Rig-owned files (hooks, commands, processes) when
unchanged, detects customizations and prompts, and always skips user-owned files
(`CLAUDE.md`, `rules/`, `memory/`, `.github/`).

---

### 7 — New machine setup

When re-cloning a project that already has The Rig installed:

```bash
# 1. Clone The Rig to a permanent location
git clone https://github.com/laudtetteh/the-rig.git ~/tools/the-rig

# 2. Install the global layer
cd ~/tools/the-rig
./install.sh --global-only --strategy merge

# 3. Fill in your personal profile
$EDITOR ~/.your-ai-contexts/PROFILE.md

# 4. Clone your project
git clone <project-url> ~/code/my-project

# 5. Re-run the project installer (wires hooks, restores local files)
./install.sh \
  --project-only \
  --target ~/code/my-project \
  --tracking repo \
  --strategy merge
```

If the project uses stealth or external tracking, use the same `--tracking` and
`--rig-dir` values as the original install. The `.rigpath` file in the project root
records the external `.rig/` path — read it to know where `.rig/` should be.

---

### 8 — Both layers at once (fresh machine, fresh project)

```bash
cd ~/tools/the-rig
./install.sh \
  --target /path/to/project \
  --tracking repo \
  --strategy merge \
  --project-name "MyProject"
# (omitting --global-only and --project-only runs both layers)
```

---

## What `/rig-install` does

The `/rig-install` slash command (available when working inside the Rig repo) asks
the user three questions, then emits the exact command for their scenario. It is a
thin wrapper over this document — run it when you need guided install selection,
refer here for raw flag reference.

---

## Post-install checklist

After any install, verify:

```bash
# Hooks are executable
ls -la /path/to/project/.claude/hooks/
ls -la /path/to/project/.husky/

# settings.json wired
cat /path/to/project/.claude/settings.json | grep pre-tool

# Test suite passes (run from the Rig repo, not the project)
bats tests/
```

For stealth/external installs, also confirm:
```bash
# .rigpath exists and points to the right place
cat /path/to/project/.rigpath

# No Rig traces in git status
git -C /path/to/project status
```
