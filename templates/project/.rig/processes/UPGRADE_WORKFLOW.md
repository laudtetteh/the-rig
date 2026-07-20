# UPGRADE_WORKFLOW.md — Upgrading The Rig

> Use this when upgrading The Rig in this project.
> Read before running the installer — each failure mode below is real and
> has been observed in the field.

---

## Overview

The Rig has two upgrade targets on this machine:

1. **`~/tools/the-rig`** — the installer source (shared across all projects)
2. **Global layer** — `~/.claude/CLAUDE.md` + `~/.claude/skills/`
3. **Project layer** — `.claude/hooks/`, `.claude/commands/`, `.rig/processes/`, `.husky/`

The installer (`install.sh`) handles the project layer automatically via its **Upgrade** strategy.
The global `CLAUDE.md` requires a manual diff + surgical edit (see below).

---

## Pre-flight checklist

Before starting:

- [ ] Run `/wrap` to snapshot current session state
- [ ] Check for `.rig/memory/.post-merge-pending` — if present, run `/post-merge` first
- [ ] Note the current version: `cat .rig/VERSION`
- [ ] Confirm no in-flight task work you don't want to checkpoint

---

## Step 1 — Pull the installer source to latest

```bash
cd ~/tools/the-rig
git checkout main
git pull origin main
cat VERSION   # confirm expected version
```

**Critical gotcha:** `~/tools/the-rig` can accidentally end up on a feature branch.
Always verify you're on `main` before proceeding. The dev repo for The Rig itself is at
`~/code/the-rig` — that's a different repo. Do not use it as an installer source.

```bash
git -C ~/tools/the-rig branch --show-current   # must print "main"
```

If not on `main`:
```bash
git -C ~/tools/the-rig checkout main && git pull origin main
```

---

## Step 2 — Survey what changed

Before touching anything, know exactly what the upgrade will affect:

```bash
TEMPLATES=~/tools/the-rig/templates/project

for src in \
  ".claude/hooks/pre-tool.sh" \
  ".claude/hooks/post-tool.sh" \
  ".claude/hooks/stop.sh" \
  ".claude/commands/ship.md" \
  ".claude/commands/wrap.md" \
  ".claude/commands/task.md" \
  ".claude/commands/post-merge.md" \
  ".claude/commands/session-name.md" \
  ".husky/pre-commit" \
  ".husky/post-commit" \
  ".husky/commit-msg" \
  ".husky/post-merge" \
  ".rig/processes/SHIP_WORKFLOW.md" \
  ".rig/processes/NEW_TASK_WORKFLOW.md" \
  ".rig/processes/POST_MERGE_WORKFLOW.md"; do
  tpl="$TEMPLATES/$src"
  [[ -f "$tpl" ]] && result=$(diff "$src" "$tpl" 2>/dev/null) \
    && { [[ -n "$result" ]] && echo "CHANGED: $src" || echo "same:    $src"; } \
    || echo "NO_TPL:  $src"
done
```

---

## Step 3 — Upgrade the global layer (`~/.claude/CLAUDE.md`)

**Do NOT use `--strategy overwrite` for the global layer.** It replaces your
customized `~/.claude/CLAUDE.md` with the template's `[PLACEHOLDER]` values.

Instead, diff and apply changes surgically:

```bash
diff ~/.claude/CLAUDE.md ~/tools/the-rig/templates/global/CLAUDE.md
```

Apply only the changed sections. Preserve:
- The real `PROFILE_PATH` value (not `[PROFILE_PATH]`)
- Any personal customizations you've added

For skills (`~/.claude/skills/`), diff each changed one before overwriting:

```bash
for f in ~/tools/the-rig/templates/global/skills/*.md; do
  name=$(basename "$f")
  diff ~/.claude/skills/"$name" "$f" >/dev/null 2>&1 || echo "CHANGED: $name"
done
```

---

## Step 4 — Run the installer for the project layer

```bash
~/tools/the-rig/install.sh --project-only --strategy upgrade --target "$(pwd)"
```

The installer will:
- Auto-update Rig-owned files that haven't been locally modified (manifest hash matches)
- Prompt on locally modified Rig-owned files (in non-interactive mode, defaults to skip)
- Smart-merge `.claude/settings.json` without duplicating hooks
- Skip user-owned files (CLAUDE.md, rules, memory, tasks, .github)

---

## Step 5 — Fix VERSION and manifest (if needed)

The `.rig/VERSION` should be updated automatically by the upgrade. Verify:

```bash
cat .rig/VERSION   # should show the new version
```

If it still shows the old version, fix manually:

```bash
echo "X.Y.Z" > .rig/VERSION
NEW_HASH=$(shasum -a 256 .rig/VERSION | awk '{print $1}')
# Edit .rig/memory/.rig-manifest and replace the old VERSION hash with $NEW_HASH
```

---

## Step 6 — Verify

```bash
cat .rig/VERSION                         # confirm new version
cat .claude/settings.json | python3 -c \
  "import json,sys; s=json.load(sys.stdin); \
   [print(k, len(v), 'entries') for k,v in s.get('hooks',{}).items()]"
                                         # confirm exactly 1 entry per hook event
ls .claude/commands/                     # confirm all commands present
git diff --stat                          # review all changes before committing
```

---

## Step 7 — Commit the upgrade

After verifying the installed files, decide how to commit them.

```bash
git diff --stat   # count the modified files
```

| Files changed | Strategy |
|---|---|
| 1–3 files | Direct `chore(rig):` commit to `[BASE_BRANCH]` acceptable if `housekeeping: direct-push` |
| 4+ files | **Branch + PR** — regardless of `housekeeping:` setting |

For any upgrade that modifies 4 or more files (hooks, commands, process files, VERSION):

```bash
# Replace X.Y.Z with the new version
git checkout -b chore/rig-upgrade-vX.Y.Z
git add -f .claude/ .husky/ .rig/processes/ .rig/rules/ .rig/VERSION
git commit -m "chore(rig): upgrade to The Rig vX.Y.Z [#N]"
gh pr create --title "chore(rig): upgrade to vX.Y.Z" \
  --body "Upgrades The Rig from vOLD to vNEW. See CHANGELOG for details."
```

> **Why branch + PR for upgrades?** `housekeeping: direct-push` governs memory commits
> (`PROGRESS.md`, task file moves, `chore(post-merge)`) — not upgrades that rewrite hook
> scripts, commands, and process files. Those changes affect every session going forward and
> warrant review, even on solo projects.

---

## Known gotchas when extending hooks

**`git add` inside a pre-commit hook fails on Git 2.39+**

Git 2.39+ holds the index lock for the entire duration of the pre-commit hook. Any
`git add` call inside the hook (or scripts it invokes) fails with:

```
fatal: Unable to create '.git/index.lock': File exists.
Another git process seems to be running in this repository
```

Use `git update-index --add <file>` instead — it stages individual files without
acquiring the index lock and works correctly inside hooks on all Git versions.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `~/tools/the-rig` is on a feature branch | `cd ~/tools/the-rig && git checkout main && git pull` |
| `settings.json` has duplicate hook entries | Remove duplicates manually; each event should have exactly one entry |
| `.rig/VERSION` still shows old version after installer | Update manually: `echo "X.Y.Z" > .rig/VERSION` then fix manifest hash |
| A Rig-owned file wasn't updated (installer said "Customized") | Copy the template manually: `cp ~/tools/the-rig/templates/project/<path> <dest>` |
| Global CLAUDE.md was overwritten with placeholders | Restore from `.rig-backup/` and re-apply surgical edits |

---

## Notes on the two Rig repos on this machine

- **`~/tools/the-rig`** — stable installer source. Always on `main`. Never develop here.
- **`~/code/the-rig`** — active dev repo for The Rig itself. Can be on any branch.
  Do NOT use this as an installer source for production projects.
