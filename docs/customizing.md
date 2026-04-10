# Customizing The Rig

How to adapt The Rig for your stack, team size, and workflow preferences.

---

## What to customize vs. what to leave alone

| Component | Customize | Leave alone |
|---|---|---|
| `CLAUDE.md` (global) | Stack defaults, personal sections | Hard rules, memory discipline, working style |
| `CLAUDE.md` (project) | Everything — it's project-specific | — |
| `PROJECT_BRIEF.md` | All of it — fill in your project | — |
| `rules/coding-standards.md` | All of it — fill in your stack's conventions | Structure (sections by runtime) |
| `rules/security.md` | Project-specific additions section | Non-negotiables (top of file) |
| `.claude/hooks/pre-tool.sh` | `BLOCKED_PATHS` array | `RIG_PROTECTED` block, tool name casing (`Write`, `Edit`) |
| `.claude/commands/task.md` | Autonomy/check-in/risk default levels | Wizard structure and operating mode persistence |
| `.husky/filter-commit-message-inplace.sh` | Add patterns for other AI tools | Existing patterns |
| `.gitleaks.toml` | Allowlist entries | `useDefault = true` |
| Processes | Scope and step details | Core sequence and gate logic |

---

## Adapting for your language stack

### Python-only project
In `rules/coding-standards.md`: delete the TypeScript section, fill in Python
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

The `RIG_PROTECTED` block above `BLOCKED_PATHS` protects The Rig's own governance files.
Don't modify it directly — use `/propose` instead.

---

## Adjusting the intake wizard defaults

`/task` defaults to **Medium autonomy / Normal check-ins / Balanced risk**. If your
workflow consistently runs at a different spice level, update the defaults in
`templates/project/.claude/commands/task.md`:

```markdown
Default: **3 — High (Autonomous)**
```

You can also update `tasks/backlog/TASK_example.md` — the `## Operating mode` table
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

Edit `processes/SHIP_WORKFLOW.md` Step 1. Add or remove checklist items to match your
project's requirements. Common additions:

- Accessibility check for UI changes
- Migration review gate for database changes
- Performance regression check for hot paths
- Dependency license check for new packages

---

## Scaling to a team

The Rig was designed for solo or small-team use. For larger teams:

**Global layer**: Each engineer installs their own global layer. The personal profile
is individual — don't share it. The `CLAUDE.md` global template should be the same
across the team (standardized hard rules and working style).

**Project layer**: Commit the project layer to the repo. Every team member gets the
same rules and workflows.

**Memory files**: `PROGRESS.md` and `ERRORS.md` are committed and shared — everyone
sees the same build history and pitfall log. `CONTEXT_SNAPSHOT.md` is gitignored and
machine-local — each engineer has their own.

**Task files**: One task per `tasks/active/` file per engineer. Use naming conventions
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

## Adding a decisions log

The memory system has `PROGRESS.md` (what shipped) and `ERRORS.md` (what went wrong),
but not a structured decisions log. If your project benefits from explicit decision
records, add `memory/DECISIONS.md`:

```markdown
# Decisions log

## [YYYY-MM-DD] — [Short title]

**Context**: Why this decision needed to be made
**Decision**: What was chosen
**Rejected**: What was considered and not chosen
**Rationale**: Why
**Consequences**: What this decision implies going forward
```

Reference it in the project `CLAUDE.md` context-loading sequence.

---

## Upgrading The Rig

When a new version of The Rig is released, pull the latest from the repo and re-run
the installer against your project:

```bash
cd the-rig && git pull
./install.sh --project-only
```

Choose **Merge** as the collision strategy. This will:
- Add any new template files that don't exist yet
- Smart-merge `.claude/settings.json` (new hooks added without overwriting yours)
- Skip all existing files (your customizations are preserved)

After upgrading, review the CHANGELOG for any manual steps — some releases may
require updating `rules/` or `processes/` files that the merge strategy skips.
