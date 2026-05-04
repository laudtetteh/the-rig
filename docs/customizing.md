# Customizing The Rig

How to adapt The Rig for your stack, team size, and workflow preferences.

---

## What to customize vs. what to leave alone

| Component | Customize | Leave alone |
|---|---|---|
| `CLAUDE.md` (global) | Stack defaults, personal sections | Hard rules, memory discipline, working style |
| `CLAUDE.md` (project) | Everything — it's project-specific | — |
| `PROJECT_BRIEF.md` | All of it — fill in your project | — |
| `.rig/rules/coding-standards.md` | All of it — fill in your stack's conventions | Structure (sections by runtime) |
| `.rig/rules/security.md` | Project-specific additions section | Non-negotiables (top of file) |
| `.claude/hooks/pre-tool.sh` | `BLOCKED_PATHS` array | `RIG_PROTECTED` block, tool name casing (`Write`, `Edit`) |
| `.claude/commands/task.md` | Autonomy/check-in/risk default levels | Wizard structure and operating mode persistence |
| `.husky/filter-commit-message-inplace.sh` | Add patterns for other AI tools | Existing patterns |
| `.gitleaks.toml` | Allowlist entries | `useDefault = true` |
| Processes | Scope and step details | Core sequence and gate logic |

---

## Adapting for your language stack

### Python-only project
In `.rig/rules/coding-standards.md`: delete the TypeScript section, fill in Python
conventions fully. Adjust imports section for your actual toolchain (Black, isort,
mypy, etc.).

### Node/TypeScript-only project
Delete the Python section. Expand the TypeScript section with your framework
conventions (React, Express, etc.).

### Go, Rust, Ruby, or any other language
The `coding-standards.md` template uses `[Runtime 1]` / `[Runtime 2]` as placeholder
headings — rename them to your languages and fill in the conventions. The structure
(naming, types, docs, general rules) applies to any typed language.

---

## Configuring protected paths

Edit `.claude/hooks/pre-tool.sh` and update the `BLOCKED_PATHS` array:

```bash
BLOCKED_PATHS=(
  ".env.production"       # almost always want this
  "migrations/"           # uncomment if you run migrations manually
  "data/approved/"        # project-specific curated data
  "secrets/"              # any directory with sensitive files
)
```

The matching is substring-based — any file path containing the string will be blocked.
Keep entries specific enough to not accidentally block legitimate paths.

The `RIG_PROTECTED` block above `BLOCKED_PATHS` protects The Rig's own governance files
(`.rig/processes/`, `.rig/rules/`, `.husky/`, `CLAUDE.md`, `.claude/hooks/`).
Don't modify it directly — use `/propose` instead.

---

## Adjusting the intake wizard defaults

`/task` defaults to **Medium autonomy / Normal check-ins / Balanced risk**. If your
workflow consistently runs at a different spice level, update the defaults in
`templates/project/.claude/commands/task.md`:

```markdown
Default: **3 — High (Autonomous)**
```

You can also update `.rig/tasks/backlog/TASK_example.md` — the `## Operating mode` table
is pre-filled with defaults. Change those values and every new task starts with your
preferred settings.

---

## Configuring protected paths for /propose

The governance gate in `/propose` mirrors the `RIG_PROTECTED` list in `pre-tool.sh`.
If you add new governance files that should require a proposal before modification,
add them to both places:

1. `pre-tool.sh` → `RIG_PROTECTED` array
2. `commands/propose.md` → "When to use it" section

---

## Adding more slash commands

Create a new `.md` file in `.claude/commands/`. The filename becomes the command name.
Structure follows the existing commands: what it does, usage, steps, notes.

Example — `/review-pr`:

```markdown
# Command: /review-pr

Runs the code-review skill against the current diff.

## What this does
1. Gets the diff for the current branch vs main
2. Invokes the code-review skill
3. Reports blockers first, then warnings, then suggestions

## Usage
/review-pr
```

---

## Adjusting the pre-ship checklist

Edit `.rig/processes/SHIP_WORKFLOW.md` Step 1. Add or remove checklist items to match your
project's requirements. Common additions:

- Accessibility check for UI changes
- Migration review gate for database changes
- Performance regression check for hot paths
- Dependency license check for new packages

---

## Keeping .rig/ invisible to teammates

If you're using The Rig on a shared repo where teammates don't use it, you have
two options to avoid `.rig/` showing up in their `git status`.

### Option A — Local gitignore (simplest)

The installer offers this as a tracking choice. It adds `.rig/` to
`.git/info/exclude`, which is per-clone and never committed. Teammates don't see
it; no `.gitignore` change is needed.

To do it manually after install:

```bash
echo ".rig/" >> .git/info/exclude
```

### Option B — External directory

Install `.rig/` to a path outside the repo entirely. Pass `--rig-dir` to the
installer:

```bash
~/tools/the-rig/install.sh --project-only --rig-dir ~/.rig/projects/my-project
```

Or choose option 3 in the interactive tracking prompt. The installer will:

1. Install all `.rig/` files to the external path
2. Write a `.rigpath` file in the project root containing the external path
3. Add `.rigpath` to `.git/info/exclude` automatically
4. Update `CLAUDE.md`'s `@` imports and context-loading paths to use the
   absolute external location
5. Update the hooks (`pre-tool.sh`, `post-tool.sh`) to resolve `RIG_DIR` via
   `.rigpath` at runtime — no hardcoded paths

The project root stays clean. The agent finds its memory and rules via
`.rigpath`. Teammates never see any of it.

---

## Scaling to a team

The Rig was designed for solo or small-team use. For larger teams:

**Global layer**: Each engineer installs their own global layer. The personal profile
is individual — don't share it. The `CLAUDE.md` global template should be the same
across the team (standardized hard rules and working style).

**Project layer**: Commit the project layer to the repo. Every team member gets the
same rules and workflows. If some engineers don't use The Rig, use the local
gitignore approach above.

**Memory files**: `PROGRESS.md` and `ERRORS.md` are committed and shared — everyone
sees the same build history and pitfall log. `CONTEXT_SNAPSHOT.md` is gitignored and
machine-local — each engineer has their own.

**Task files**: One task per `.rig/tasks/active/` file per engineer. Use naming conventions
to avoid collisions: `TASK_[engineer-initials]-[feature].md`.

---

## Using without Husky (non-Node projects)

The Husky hooks are POSIX shell scripts that work independently of Husky. You can
wire them directly:

```bash
# Copy hooks to .git/hooks/
cp .husky/pre-commit .git/hooks/pre-commit
cp .husky/commit-msg .git/hooks/commit-msg
cp .husky/post-commit .git/hooks/post-commit
cp .husky/filter-commit-message-inplace.sh .husky/

# Set executable bits
chmod +x .git/hooks/pre-commit .git/hooks/commit-msg .git/hooks/post-commit
```

The `.git/hooks/` approach works for any project regardless of language. The downside:
hooks in `.git/hooks/` are not committed to the repo, so teammates must set them up
manually. Husky solves this by checking in hooks to `.husky/` and auto-installing them
via `prepare` script in `package.json`.

---

## Disabling the AI trailer stripping

If you want co-author credits to appear in your history (e.g., you're building a team
project where attribution matters), comment out or remove the `commit-msg` and
`post-commit` hooks from `.husky/`.

The `pre-commit` (gitleaks) is independent and unaffected.

---

## Replacing gitleaks with another secret scanner

Edit `.husky/pre-commit`. Replace the gitleaks block with your scanner of choice.
The hook structure (check for binary → run scanner → block on non-zero exit) works
for any scanner that exits non-zero on detection.

Common alternatives: `trufflehog`, `git-secrets`, `detect-secrets`.

---

## The decisions log

`.rig/memory/DECISIONS.md` is included in the default scaffold. The agent logs to it
when a significant architectural, product, or process decision is made — especially
one that closes off alternatives or would surprise a future reader.

Format per entry:

```markdown
## [YYYY-MM-DD] — [Short title]

**Context**: Why this decision needed to be made
**Decision**: What was chosen
**Rejected**: What was considered and not chosen
**Rationale**: Why
**Consequences**: What this decision implies going forward
```

Unlike `CONTEXT_SNAPSHOT.md`, this file is committed — decisions are project history.
The project `CLAUDE.md` context-loading sequence already references it.

---

## Upgrading The Rig

When a new version of The Rig is released, pull the latest from the repo and re-run
the installer against your project:

```bash
cd ~/tools/the-rig && git pull
./install.sh --project-only
```

Choose **Upgrade (option 3)** from the intent menu. This is the recommended
path for all upgrades. It:

- **Auto-updates** Rig-owned files (hooks, commands, process workflows, husky hooks)
  that you haven't modified since install — no prompts, no friction
- **Prompts with a diff** for any Rig-owned file you've customized — you see exactly
  what changed before deciding to overwrite or keep your version
- **Skips** user-owned files entirely (`CLAUDE.md`, `.rig/rules/`, `.rig/memory/`,
  `.rig/tasks/`, `.github/`) — your customizations are always preserved
- **Smart-merges** `.claude/settings.json` — new hooks are added without duplicating
  anything already present

### How it works: the manifest

The installer records the SHA256 hash of each Rig-owned file in
`.rig/memory/.rig-manifest` on every install. This is committed to the repo.

On upgrade, for each Rig-owned file:

| Condition | What happens |
|---|---|
| Dest hash == new template hash | Already up to date — skipped |
| Dest hash == manifest hash | Unmodified since install — overwritten silently (backup kept) |
| Dest hash != manifest hash | You've customized it — diff shown, you choose: overwrite / skip |
| No manifest entry | First upgrade (manifest didn't exist yet) — overwritten silently |

Backups are written to `.rig-backup/<timestamp>/` before any overwrite, so nothing
is ever lost.

### Manifest-aware customization

Files in the **Rig-owned** category that you commonly want to customize:

| File | Customizable section |
|---|---|
| `.claude/hooks/pre-tool.sh` | `BLOCKED_PATHS` array (project-specific protected paths) |
| `.claude/commands/ship.md` | Steps can be extended with project-specific checks |
| `.rig/processes/*.md` | Steps can be extended; core gate logic should be preserved |
| `.husky/filter-commit-message-inplace.sh` | Add patterns for other AI tools |

The Upgrade strategy will detect changes to these files and prompt before overwriting.
Your customizations are safe.

### Choosing the right intent

The installer asks "What are you doing?" and derives the right strategy from your
answer. You don't need to think about strategy names:

| Intent | Use when | Underlying strategy |
|---|---|---|
| **1) First install** | Setting up The Rig on a new machine | merge (global + project) |
| **2) New project** | Scaffolding into a new or existing project | merge (project only) |
| **3) Upgrade** | Updating an existing Rig install — recommended | upgrade (project only) |
| **4) Repair** | Resetting Rig-owned files to a clean state | overwrite (project only) |
| **5) Custom** | Full control over strategy and components | you choose |

For scripting and CI, the `--strategy` flag accepts the internal strategy name
directly (merge / skip / overwrite / upgrade / interactive), bypassing the intent
menu entirely.

After upgrading, review the CHANGELOG for any manual steps — some releases may add
new fields to `.rig/rules/` files or project `CLAUDE.md` that the Upgrade intent
skips (since those are user-owned).
