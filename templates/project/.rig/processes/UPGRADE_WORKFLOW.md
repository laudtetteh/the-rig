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
| The upgrade completed but you want it undone | `bin/rig upgrade rollback --last --dry-run`, review the plan, then `bin/rig upgrade rollback --id <rollback-id> --confirm <rollback-id>`. Restores only what that upgrade changed |
| Rollback refuses a file as "edited since the upgrade" | Working as intended — something changed it after the upgrade and rollback will not discard that. Resolve the file yourself, then re-run |
| Rollback exits `3` | Some paths were refused. Nothing went wrong, but the upgrade is not fully reversed — read `refused[]` in `--json`. Exit `0` means fully undone, `70` means a restore actually failed |
| `--dry-run` and `--confirm` together is rejected | Deliberate. They are mutually exclusive so the belt-and-braces invocation can never be the destructive one |
| Rollback says "no upgrade reports found" | Either the project predates durable reports, or the run changed nothing so no report was written. A first install never writes one — there is no earlier state to return to |
| Every file refuses with a base-resolution reason | The installer source has no reachable release tags. `git -C ~/tools/the-rig fetch --tags` and re-run — this is not a genuine conflict |
| An upgrade was *interrupted* (killed, disk full, permission error) | Use `install.sh --recover`, not rollback. Recovery restores an in-flight transaction; rollback undoes a completed one |

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

Both modes run the same artifact discovery/classification as `--strategy
upgrade` — there is one classification code path in `install.sh`, shared by all
three strategies. After classification, agent mode has an additional guarded
convergence step for customized Rig-owned files. It preserves local edits, adds
incoming Rig changes when the merge tool can do so defensively, dedupes where
the structured merge supports it, and leaves true conflicts untouched with
specific repair guidance.

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

### `agent-upgrade` — apply guarded convergence

```bash
install.sh --project-only --target "$(pwd)" --tracking repo --strategy agent-upgrade
```

- Applies the safe file operations `--strategy upgrade` already applies
  non-interactively: creates missing tracked files, updates files whose
  installed hash still matches the manifest baseline, smart-merges
  `.claude/settings.json`, and retires obsolete Rig-owned artifacts (for
  example the legacy `session-end.sh` hook merged into `stop.sh`).
- Attempts guarded convergence for customized Rig-owned files before reporting
  them as manual-review conflicts.
- Never prompts, even if stdin happens to be a TTY.
- Never silently overwrites a customized file and never silently accepts a stale
  customized file as converged. A customized file is updated only when the
  convergence helper can preserve local edits and apply incoming changes
  defensively; otherwise it is left untouched and reported.
- Prints the same JSON schema as `agent-plan` (with `"mode":"apply"`) and
  uses the same exit codes (`0` success, `3` refused).
- Writes a durable upgrade report and adds `report_path` and `rollback_id` to
  the JSON (see below).

### Trusted merge bases

Guarded convergence needs to know which side actually changed a customized
file, which means it needs the file's original content — not just its hash.
That base is recovered **by content, not by version number**: the installer
takes the baseline SHA256 the manifest recorded and finds the template revision
that reproduces it exactly, checking the installer's checked-out templates
first and then its release tags. A base is accepted only on exact hash
equality, so it is proven rather than assumed.

Two consequences worth knowing:

- Projects tracked only in the **legacy flat manifest** — which records a hash
  and nothing else, with no `base_revision` — converge fine. The recorded hash
  is all the resolver needs.
- The installer source must be a git checkout whose **release tags are
  reachable**. In a shallow clone with no tags, only the currently checked-out
  template can serve as a base; anything older refuses with that reason rather
  than guessing. `git -C <installer-source> fetch --tags` restores full
  coverage.

When a base is proven, Markdown prose bodies and unstructured files merge
line-level, so edits to different parts of the same file combine cleanly.
Overlapping edits to the same region remain a true conflict and are reported
hunk by hunk. Without a proven base the installer falls back to whole-file
comparison and refuses on any difference.

### Durable upgrade reports

Every completed upgrade-family mutation writes one report:

- repo/local tracking: `.rig/upgrade-reports/YYYYMMDD_HHMMSS_PID.json`
- stealth/external tracking: `$RIG_DIR/upgrade-reports/YYYYMMDD_HHMMSS_PID.json`

`agent-plan` writes **no** report — it is a zero-write classification pass.

The report is a rollback contract rather than an audit log. Per changed path it
records the operation, the storage root and relative path, before/after hash,
mode and type, and either a backup path or an explicit `absent_before`.
Alongside that it records the rollback id, version before/after, backup root,
preflight snapshot, and a snapshot of the manifest pair and `.rig/VERSION` as
they stood before the run.

The operations actually emitted are `created`, `modified`, and `deleted`. The
schema reserves `mode-only` and `manifest-only` for changes that alter nothing
but a file's mode or its manifest entry; nothing emits them today, so do not
rely on their presence.

The report JSON itself records paths and metadata only — never file contents,
and never the recovery journal. It is written `0600`. Note that the pre-run
manifest pair and `.rig/VERSION` *are* copied verbatim into a sibling
`YYYYMMDD_HHMMSS_PID.metadata/` directory next to the report, because rollback has
to restore them; that directory is mode `0700`.

### Undoing a completed upgrade

```bash
bin/rig upgrade rollback --last --dry-run
bin/rig upgrade rollback --id <rollback-id> --dry-run
bin/rig upgrade rollback --id <rollback-id> --confirm <rollback-id>
```

Rollback restores only the paths the selected report records as changed — never
the whole preflight snapshot, which would also revert unrelated work done
since. It verifies each path still matches the report's recorded after-state
before touching it, and refuses:

- any path edited since the upgrade (your later work is never discarded);
- any destination that is now a symlink, a directory, or the wrong type;
- any path that would escape its storage root, or cross a symlinked parent;
- any change whose backup is missing or no longer matches the recorded
  pre-state.

It restores the manifest pair and `.rig/VERSION` alongside the files — but only
when every path succeeded. Reverting the bookkeeping while some file stayed at
its post-upgrade content would claim a state the tree is not in, and every later
upgrade would then misclassify files as customized. It writes its own durable
rollback report either way.

Exit codes: `0` fully undone, `3` some paths refused (nothing went wrong, but
the upgrade is not fully reversed), `70` a restore actually failed. `3` matches
the agent-mode refusal contract above, so a caller can tell "undone" from
"declined" without parsing the JSON.

> `install.sh --recover` is a different operation: it restores an **interrupted**
> transaction from `.rig-backup/.in-progress`. Rollback undoes a **completed**
> run. Use recovery for a run that died partway; use rollback for a run that
> finished and that you have decided against.

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
  ],
  "report_path": "absolute path to this run's durable report",
  "rollback_id": "identifier to pass to bin/rig upgrade rollback --id"
}
```

`report_path` and `rollback_id` appear only when a real mutation was applied,
so `agent-plan` output never carries them and their absence means "no rollback
candidate", not an error. Their presence adds no extra stdout narration — the
document is still exactly one machine-readable JSON object.

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

### Structure-aware/three-way convergence (`converged` classification)

> Implemented under issue #444 lane 444-C, in PR #452. As of this writing
> that PR is open with CI pending and has not merged to `main` — the
> behavior below reflects the PR's diff, read directly rather than assumed.
> Re-verify this section once #452 actually merges, in case anything shifted
> during review.

Lane 444-C adds a real merge step for customized files with a known,
structured format, reachable only from `agent-plan`/`agent-upgrade` (every
interactive, skip, overwrite, merge, and plain non-interactive `--strategy
upgrade` run is byte-for-byte unaffected). When a customized file would
otherwise fall into the `skipped-customized` bucket, the file's extension and
path first route it to one of four narrowly-scoped merge helpers under
`installer/`:

| File pattern | Helper |
|---|---|
| `*.json` (except `settings.json`, which is always smart-merged elsewhere and never reaches this path) | `merge-json.py` — key-level three-way merge |
| `*.toml` | `merge-toml.py` — section/key-aware merge |
| `.claude/commands/*.md`, `.claude/agents/*.md`, `.rig/processes/*.md` | `merge-frontmatter-markdown.py` — structural frontmatter merge; whole-side-wins body when only one side changed, explicit conflict when both changed |
| everything else | `merge-text3way.py` — plain-text fallback; whole-file rules first, then a line-level three-way merge when a trusted base is available |

A trusted base **is** supplied: `attempt_convergence_merge()` resolves one via
`installer/resolve-historical-base.py` and passes `--base` to every helper
above. With it, Markdown prose bodies and unstructured text merge line-level
through `git merge-file`, so edits to different parts of the same file combine
cleanly and only genuinely overlapping edits conflict.

When no base can be *proven* — see "Trusted merge bases" above — the helpers
run without `--base` and fall back to the conservative rule: a key or line that
differs between the customized file and the incoming template is reported as a
conflict rather than guessed. A refusal in that state usually means the
installer source has no reachable release tags, not that the file genuinely
conflicts; the refusal reason says which.

A successful merge is recorded as a new `converged` classification instead of
forcing a refusal:

```json
{"path":"relative/path","classification":"converged","action":"merge","reason":"local customization preserved while incorporating conflict-free incoming Rig changes via structure-aware or three-way merge"}
```

An unresolved merge conflict still produces the existing `skipped-customized`
classification and `status: "refused"`/exit `3` behavior described above, but
each `conflicts[]` entry gains a `details` array naming the exact keys or
line ranges that conflicted (compact JSON, one entry per conflicting
key/line), instead of only a generic path-level reason:

```json
{"path":"relative/path","reason":"local content differs from the recorded Rig baseline (customized)","repair_guidance":"Resolve manually and re-run, or restore the file from .rig-backup/ and accept the incoming template on the next upgrade.","details":["settings.timeout","hooks.pre-commit"]}
```

The `summary` object gains a matching `converged` count alongside the fields
already documented above.

### Stale-manifest categories for every tracking layout

> Implemented under issue #444 lanes 444-E/444-F/444-G, consolidated in PR
> #451. As of this writing that PR is open with CI pending and has not
> merged to `main` — the behavior below reflects the PR's diff, read directly
> rather than assumed. Re-verify this section once #451 actually merges.

Before this lane, external and stealth manifests (which mix ordinary
project-rooted paths with `.rig/…` paths that were relocated to the external
Rig directory) resolved every tracked entry against a single root, which made
stale-manifest auditing either falsely flag every `.rig/…` entry or make
every other entry unreachable — so the audit was skipped entirely for those
two layouts. It now resolves each entry against the correct root (project
root for ordinary paths, the external Rig directory for `.rig/…` paths) and
reports four disjoint categories instead of a single flat "missing" list:

| Category | Meaning | Auto-repaired by `--repair-stale`? |
|---|---|---|
| `missing` | The tracked path no longer exists at all | Yes — the only category this is ever true for, because removing the manifest entry doesn't touch a filesystem path that isn't there |
| `wrong-type` | The path exists, but its type (file vs. directory) no longer matches what the manifest recorded | No — always requires manual review |
| `dangling-symlink` | The path is a symlink whose target no longer exists | No — always requires manual review |
| `unexpected-symlink` | The path is now a symlink where the manifest recorded a non-symlink type | No — always requires manual review |

The three non-`missing` categories are never auto-repaired, on purpose:
silently rewriting the manifest for a path whose real-world state doesn't
match what was recorded would be exactly the kind of silent
accept-as-converged behavior issue #444's locked policy forbids. In agent
mode, any unrepaired stale entry (not just `wrong-type`/symlink findings —
a `missing` entry left unrepaired because `--repair-stale` wasn't passed
counts too) now also drives `status: "refused"`/exit `3`, the same as a
customized or conflicting file.

### Complete transaction/backup coverage for direct-writer mutations

> Implemented under issue #444 lane 444-F, in the same PR #451 referenced
> above (open, CI pending as of this writing).

Several install/upgrade code paths mutate a destination file in place rather
than copying a template through `copy_file()` — settings-merge writes,
`.rigpath`, `.rig/VERSION`, install-target state metadata, `.codex/config.toml`,
and `[PLACEHOLDER]` substitutions. Before this lane, none of those call sites
invoked `backup_file()` themselves, so a run interrupted between two of them
had nothing recorded to roll back to. They now route through
`upgrade_prepare_mutation()`, which journals and backs up an existing
regular-file destination before the caller is allowed to mutate it — the
same transaction machinery `copy_file()`'s own upgrade path already used, so
`--recover` restores these mutations identically to any other tracked write.

### Safe `.git/hooks/` lifecycle in stealth mode

> Implemented under issue #444 lane 444-G (PR #451), and hardened in v1.25.0
> after `/rig-surface-review`'s first real run found the original fix only
> actually applied under `--strategy upgrade` — not `merge`, the default for
> every fresh install (see `docs/decisions.md` #20 and
> `docs/lessons-learned.md` #15 in The Rig's own repo).

Stealth-mode `.git/hooks/` writes previously bypassed the manifest and
backup system entirely (a plain `cp` over whatever was already there). They
are now manifest-tracked and customization-aware, using the same
missing/unmodified/customized states as every other Rig-owned artifact: a
hook with no manifest entry, a hash mismatch against its manifest entry, or a
symlink destination is treated as customized or foreign, never silently
overwritten — under every install strategy, not only `upgrade`. In ordinary
interactive/non-interactive (non-agent) runs the hook is still always
installed, but a customized one is backed up first. In `agent-upgrade` mode
(`AGENT_MODE=apply`), a customized hook is never overwritten — it is refused
and reported in `conflicts[]` via the existing `skipped-customized`
classification, exactly like any other customized artifact.

### Post-upgrade verification: `bin/rig doctor` gates

> Implemented under issue #444 lane 444-H (merged). These gates run inside
> the installed project's own `bin/rig doctor` — a separate command from
> `install.sh` itself. `install.sh` and `agent-upgrade` never invoke it
> themselves (a bare `install.sh --strategy agent-upgrade` run is still just
> the file-convergence engine, with no doctor call at all). As of issue #456,
> `/rig-upgrade` Phase 3d does invoke `bin/rig doctor --json` automatically
> after every project-layer upgrade (both `agent` and `classic` mode — see
> `templates/project/.claude/commands/rig-upgrade.md`, section 3d) and
> surfaces any gate failure before declaring the command complete. Running
> `install.sh` or `agent-upgrade` directly, outside of `/rig-upgrade`, still
> requires a manual `bin/rig doctor` (or `bin/rig doctor --json`) call
> afterward to check these gates.

| Gate | Verifies | Reports "skipped" (not "failed") when |
|---|---|---|
| `manifest_provenance` | Every `.rig-manifest.json` entry's `owner`/`source`/`generator`/`provider`/`type` is within its known vocabulary (delegates to `installer/validate-manifest-provenance.py`) | No manifest metadata file exists, or the validator script isn't colocated with this checkout (true for every ordinary downstream install — that script never ships into a target project) |
| `stealth_status` | No Rig-generated artifact is tracked by git or visible-and-unignored in a stealth/external install (delegates to `installer/audit-stealth.py`) | The project isn't a stealth/external install, the audit script isn't colocated, or the git directory can't be classified (e.g. a linked worktree) |
| `manifest_mode_hash` | Every Rig-owned artifact's file mode and content hash still match the manifest (catches hand-edits made outside the installer) | No manifest metadata file exists |
| `stale_manifest_entries` | No manifest entry points at a path that no longer exists on disk at all | No manifest metadata file exists |
| `idempotence` | Not verified live — `doctor` is read-only and has no safe way to mutate/roll back a real project tree from inside itself. Always reports the documented procedure instead of fabricating a live result | Never "fails" on its own; always points to `bats tests/test_install_idempotence.bats` |

`installer/validate-manifest-provenance.py` and `installer/audit-stealth.py`
are release-engineering tools that live only in The Rig's own source repo.
Neither ships into a downstream target project, so `manifest_provenance` and
`stealth_status` permanently report "skipped" with an explanatory detail
string on an ordinary install — that is expected steady state, not a defect.

### Repair guidance by finding

**Stealth `tracked_leak` / `untracked_leak` (from `stealth_status` or a
direct `installer/audit-stealth.py` run):** run
`python3 installer/repair-stealth.py <target>`. It appends any missing
pattern to `.git/info/exclude` for artifacts classified as a leak — additive
only, never rewrites or removes an existing exclude line, never touches the
git index. A `tracked_leak` (a Rig-generated file that was actually
committed) is reported in the tool's `still_tracked` list but is **not**
fixed automatically, because an exclude pattern has no effect on a path git
already tracks — untrack it explicitly with `git rm --cached <path>`, review
the resulting diff, then commit.

**Stale manifest entry reported as `wrong-type`, `dangling-symlink`, or
`unexpected-symlink`:** manual review required, always — see "Stale-manifest
categories" above for why these three are never auto-repaired. Inspect the
path, determine whether it's a deliberate local change or accidental drift,
and either restore the expected type or correct the manifest entry before
re-running the upgrade.

**`agent-plan`/`agent-upgrade` exits `3` with `status: "refused"`:** every
safe/convergeable action was already applied, including every conflict-free
structure-aware merge lane 444-C's convergence engine could apply — only the
files listed in `conflicts[]` are still untouched. For each one, either
resolve it manually (reconcile the customization with the incoming change,
or restore from `.rig-backup/` and re-run to accept the incoming template)
or re-run with a strategy that explicitly accepts the incoming version for
that file (interactive `--strategy upgrade` will prompt per file). Re-running
`agent-upgrade` unchanged against the same unresolved conflict refuses again
by design — that is not a bug to retry around. `/rig-upgrade` Phase 2b-agent
presents each `conflicts[]` entry (`path`/`reason`/`repair_guidance`)
automatically when running in `agent` mode — see
`templates/project/.claude/commands/rig-upgrade.md`, section 2b-agent.
