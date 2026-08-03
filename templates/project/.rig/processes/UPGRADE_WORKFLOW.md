# UPGRADE_WORKFLOW.md — Upgrading The Rig

> Upgrade both provider surfaces: Claude-native files under `.claude`/`~/.claude`, Codex configuration/hooks, and generated `.agents/skills`. Shared `.rig` contracts are authoritative; provider-specific files retain their labeled adapter role.

> Use this when upgrading The Rig in this project.
> Read before running the installer — each failure mode below is real and
> has been observed in the field.

---

## Overview

The Rig has three upgrade surfaces on this machine:

1. **`~/tools/the-rig`** — the installer source (shared across all projects)
2. **Global agent layers** — Claude `~/.claude/` and Codex `~/.agents/skills/`
3. **Project layer** — shared `.rig/` and `.husky/`, Claude `.claude/`, generated Codex `.agents/skills/`, and Codex `.codex/`

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
  ".codex/hooks.json" \
  ".codex/hooks/rig-adapter.sh" \
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

For Claude skills (`~/.claude/skills/`), diff each changed one before overwriting:

```bash
for f in ~/tools/the-rig/templates/global/skills/*.md; do
  name=$(basename "$f")
  diff ~/.claude/skills/"$name" "$f" >/dev/null 2>&1 || echo "CHANGED: $name"
done
```

Codex personal skills live under `~/.agents/skills/` and are generated from the
canonical global skill sources. Upgrade them through the installer so Claude and
Codex do not acquire independently maintained workflow text.

---

## Step 4 — Run the installer for the project layer

```bash
~/tools/the-rig/install.sh --project-only --strategy upgrade --target "$(pwd)"
```

The installer will:
- Auto-update Rig-owned files that haven't been locally modified (manifest hash matches)
- Prompt on locally modified Rig-owned files (in non-interactive mode, defaults to skip)
- Smart-merge `.claude/settings.json` without duplicating hooks
- Regenerate selected Codex skills and update Rig-owned `.codex` hook artifacts
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
test ! -d .agents/skills || find .agents/skills -name SKILL.md | sort
test ! -d .codex || bin/rig doctor --json # validate selected Codex wiring
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
git add -f .claude/ .agents/skills/ .codex/ .husky/ .rig/processes/ .rig/rules/ .rig/VERSION
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

---

## Agent-driven upgrade contract (`--strategy agent-plan` / `--strategy agent-upgrade`)

> Added under issue #444, lane 444-A. These two `--strategy` values are
> non-interactive-only: they are accepted by `install.sh --strategy <value>`
> but never offered as a numbered choice in the interactive "What are you
> doing?" menu, so an interactive human user can never land in agent mode by
> accident.

### When to use these instead of `--strategy upgrade`

Use `--strategy agent-plan` when a calling agent or script needs a
machine-readable, read-only preview of what an upgrade would do before
deciding whether to run it — for example inside `/rig-upgrade`'s survey phase
(see `templates/project/.claude/commands/rig-upgrade.md`, section 1c-bis).

Use `--strategy agent-upgrade` when a calling agent or script wants to apply
the same safe/convergeable actions `--strategy upgrade` already applies (file
creation, unmodified-file updates, `settings.json` smart-merge, obsolete-hook
retirement), but needs a single JSON result document instead of parsing
human-oriented stdout text, and needs a reliable, distinct exit code that
means "something needs a human" rather than "crashed" or "bad flag."

Both modes run the exact same artifact discovery/classification as
`--strategy upgrade` — there is one classification code path in `install.sh`,
shared by all three strategies. Neither mode performs real three-way merging
of customized files; that is out of scope for lane 444-A and is tracked as a
follow-up (lane 444-C) under #444. A customized or conflicting file is always
left exactly as `--strategy upgrade` would leave it today: untouched, and
reported for manual review.

### `agent-plan` — read-only preflight

```bash
install.sh --project-only --target "$(pwd)" --tracking repo --strategy agent-plan
```

- Performs **zero writes** to the target (or the global layer, if the global
  layer is also selected). No file is created, modified, deleted, backed up,
  or has its mode changed. No manifest entry, transaction journal, or
  target-state file is written.
- Prints exactly one JSON document on stdout (see schema below) and exits.
- Exit code `0` when `status` is `"success"`. Exit code `3` when `status` is
  `"refused"` (see below). A different exit code means a genuine fatal error
  unrelated to conflicts (for example, the target directory does not exist) —
  the same class of error that would make plain `--strategy upgrade` exit `1`
  today.

### `agent-upgrade` — apply the same convergence as `upgrade`

```bash
install.sh --project-only --target "$(pwd)" --tracking repo --strategy agent-upgrade
```

- Applies the same file operations `--strategy upgrade` already applies
  non-interactively: creates missing tracked files, updates files whose
  installed hash still matches the manifest baseline, smart-merges
  `.claude/settings.json`, and retires obsolete Rig-owned artifacts (for
  example the legacy `session-end.sh` hook merged into `stop.sh`).
- Never prompts, even if stdin happens to be a TTY.
- Never silently overwrites a customized file and never silently accepts a
  stale customized file as converged — a customized or conflicting file is
  always left untouched and reported, exactly like a non-interactive
  `--strategy upgrade` run leaves it today.
- Prints the same JSON schema as `agent-plan` (with `"mode":"apply"`) and
  uses the same exit codes (`0` success, `3` refused).

### Refusal semantics and exit code 3

If classification would place **any** file in the customized-skip or
conflict-skip bucket — anything the current interactive `--strategy upgrade`
would leave for manual review — both `agent-plan` and `agent-upgrade` set
`status` to `"refused"` in the JSON output and exit with code `3`. This is
intentional: The Rig's policy is to never silently accept a stale customized
artifact as converged. A run with zero customized or conflicting files exits
`0` with `status: "success"`, whether or not anything was actually updated.

Exit code `3` is dedicated to this contract and does not collide with the two
exit codes `install.sh` already uses elsewhere:

| Exit code | Meaning |
|---|---|
| `0` | Success (interactive/non-interactive strategies), or agent mode with `status: "success"` |
| `1` | General fatal error (used throughout `install.sh`) |
| `2` | Malformed or missing project/global target metadata (`--strategy`/`--global-agent`/`--project-agent` parsing) |
| `3` | Agent mode only: `status: "refused"` — at least one artifact needs manual review |

### JSON schema

```json
{
  "schema_version": 1,
  "mode": "plan | apply",
  "status": "success | refused | error",
  "summary": {
    "updated": 0,
    "merged": 0,
    "removed_obsolete": 0,
    "skipped_customized": 0,
    "skipped_conflict": 0,
    "skipped_untracked": 0,
    "stale": 0
  },
  "artifacts": [
    {
      "path": "relative/path/from/target/root",
      "classification": "up-to-date | unmodified-since-install | settings-mergeable | obsolete | moved-project-reference | user-owned-untracked | customized | conflict",
      "action": "none | update | merge | remove | rewrite | skip",
      "reason": "human-readable explanation of the classification"
    }
  ],
  "conflicts": [
    {
      "path": "relative/path/from/target/root",
      "reason": "human-readable explanation",
      "repair_guidance": "concrete next step for a human or a follow-up agent run"
    }
  ]
}
```

- `summary` mirrors the same `UPGRADE_*_COUNT` bookkeeping the human-oriented
  `--strategy upgrade` summary already prints (`Updated:`, `Merged:`,
  `Removed obsolete:`, `Skipped customized:`, `Skipped conflicts:`,
  `Skipped untracked user-owned:`, `Stale/missing tracked artifacts:`).
- `artifacts` contains one entry per file the classification logic actually
  evaluated (every file that contributes to `summary`, plus files found to
  already be up to date). It does not enumerate files outside that
  classification path (for example stealth git-hook installation or Husky
  initialization) — those are not part of the `UPGRADE_*_COUNT` contract
  today and are out of scope for lane 444-A.
- `conflicts` is non-empty only when `status` is `"refused"`, and contains
  exactly the artifacts whose `classification` is `"customized"` or
  `"conflict"`.
- `status: "error"` is reserved for a future lane; a genuine fatal error in
  the current implementation exits before any JSON is printed, the same way
  a fatal error in plain `--strategy upgrade` does today.

### Example: a clean plan (`status: "success"`)

```json
{"schema_version":1,"mode":"plan","status":"success","summary":{"updated":0,"merged":1,"removed_obsolete":0,"skipped_customized":0,"skipped_conflict":0,"skipped_untracked":0,"stale":0},"artifacts":[{"path":".claude/hooks/pre-tool.sh","classification":"up-to-date","action":"none","reason":"already matches the incoming Rig version; no action needed"},{"path":".claude/settings.json","classification":"settings-mergeable","action":"merge","reason":"settings.json merged (smart-merge) with the incoming Rig version"}],"conflicts":[]}
```

### Example: a refused result (`status: "refused"`, exit 3)

```json
{"schema_version":1,"mode":"apply","status":"refused","summary":{"updated":1,"merged":1,"removed_obsolete":0,"skipped_customized":1,"skipped_conflict":0,"skipped_untracked":0,"stale":0},"artifacts":[{"path":".claude/commands/status.md","classification":"unmodified-since-install","action":"update","reason":"template file updated to the incoming Rig version"},{"path":".claude/settings.json","classification":"settings-mergeable","action":"merge","reason":"settings.json merged (smart-merge) with the incoming Rig version"},{"path":"CLAUDE.md","classification":"customized","action":"skip","reason":"local content differs from the recorded Rig baseline (customized)"}],"conflicts":[{"path":"CLAUDE.md","reason":"local content differs from the recorded Rig baseline (customized)","repair_guidance":"Resolve manually and re-run, or restore the file from .rig-backup/ and accept the incoming template on the next upgrade."}]}
```

In this example, `agent-upgrade` still updated `.claude/commands/status.md`
and merged `.claude/settings.json` — the safe/convergeable actions — while
leaving `CLAUDE.md` completely untouched and reporting it in `conflicts`
with concrete repair guidance. The overall run still exits `3` because at
least one file was left for manual review.
