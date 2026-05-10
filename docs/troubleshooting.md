# Troubleshooting

Common problems and how to fix them.

---

## 1. Hooks aren't firing

**Symptom:** Claude Code makes writes or runs `git commit` without going through the
pre-tool or post-tool checks. The commit sentinel flow doesn't trigger. PROGRESS.md
auto-stubs never appear.

**Causes and fixes:**

### Hooks not executable
After a re-clone, hook scripts lose their executable bit.

```bash
chmod +x .claude/hooks/pre-tool.sh .claude/hooks/post-tool.sh .claude/hooks/stop.sh
```

### Wrong tool names in hook matchers
Claude Code tool names are **PascalCase** (`Write`, `Edit`, `Bash`). If
`.claude/settings.json` uses `snake_case` (`write_file`, `edit_file`), the hooks
silently never fire for those tools.

Check `.claude/settings.json` — every hook entry should look like:
```json
{
  "matcher": ".*",
  "hooks": [{ "type": "command", "command": ".claude/hooks/pre-tool.sh" }]
}
```

The `"matcher": ".*"` catches all tools. Don't replace it with individual tool names.

### settings.json not wired
If `.claude/settings.json` is missing the hook entries entirely, re-run the installer:

```bash
~/tools/the-rig/install.sh --project-only
# Choose: 3) Upgrade (or 4) Repair if hooks are the only issue)
```

---

## 2. Commit gate is blocking unexpectedly

**Symptom:** `git commit` is blocked with "waiting for sentinel" even though you
already said the trigger phrase. Or the sentinel file (`.rig-commit-ok`) exists but
the commit still fails.

**Causes and fixes:**

### Stale sentinel from a failed commit
If a previous commit failed after the sentinel was created but before `post-tool.sh`
could delete it, the sentinel is stale.

```bash
# Check if it exists
ls .rig/memory/.rig-commit-ok

# Delete it and start the commit flow again
rm .rig/memory/.rig-commit-ok
```

### post-tool.sh isn't running
If `post-tool.sh` never fires, the sentinel is never deleted. This causes the
next commit attempt to find the sentinel already present (which the hook may
interpret as a double-commit attempt). Fix: ensure hooks are executable and wired
(see issue #1 above).

### Running git commit outside Claude Code
The sentinel flow is enforced by the Claude Code hook. If you run `git commit`
directly in a terminal (not through Claude Code), the pre-tool hook doesn't run
and neither does the sentinel check. This is intentional — the gate is for
agent-initiated commits only.

---

## 3. PROGRESS.md is too large / session start is slow

**Symptom:** Session startup takes a long time. The agent reads PROGRESS.md in full
instead of stopping at CONTEXT_SNAPSHOT.md.

**Causes and fixes:**

### CONTEXT_SNAPSHOT.md is missing
If `/wrap` has never been run in this project, there's no snapshot and the agent
falls back to PROGRESS.md. Fix: run `/wrap` at the end of the current session.

### CONTEXT_SNAPSHOT.md is stale (more than one session old)
The `**Last updated:**` field in the snapshot is older than the current session. The
agent loads PROGRESS.md as a fallback. Fix: run `/wrap` to refresh the snapshot.

### PROGRESS.md has too many entries
`/wrap` caps PROGRESS.md at 20 entries and archives older ones to
`.rig/memory/PROGRESS_archive.md`. If the cap hasn't been hit yet (under 20 entries)
but startup is still slow, the issue is likely a missing or stale snapshot — see above.

To manually trim if `/wrap` hasn't been run recently:
```bash
# Count entries
grep -c "^## " .rig/memory/PROGRESS.md
# Then run /wrap and confirm the trim when prompted
```

---

## 4. /wrap session boundary is wrong — names the wrong session

**Symptom:** `/wrap` suggests a session name that includes work from a previous
session, or misses work from the current one.

**Cause:** The `<!-- session-end -->` boundary markers in PROGRESS.md are missing,
stale, or the wrong one was identified as "most recent."

**How the boundary works:** `stop.sh` appends `<!-- session-end YYYY-MM-DD HH:MM -->`
to PROGRESS.md automatically after every agent response. `/wrap` looks for the most
recent such marker and treats everything above it as "this session."

**Fixes:**

- If `stop.sh` wasn't wired yet (new install), there are no markers. `/wrap` falls
  back to the `**Last updated:**` date from CONTEXT_SNAPSHOT.md. Make sure that date
  reflects when the previous session ended.

- If the markers are present but `/wrap` is naming the wrong session, check for
  stale markers from previous sessions that weren't pruned. `/wrap` should prune
  all but the most recent marker after each run. If markers have accumulated,
  manually inspect `.rig/memory/PROGRESS.md` and remove the stale ones.

- After a re-clone on a new machine, PROGRESS.md travels with the repo but
  CONTEXT_SNAPSHOT.md doesn't. Run `/wrap` at the start of the first session on
  the new machine to re-establish the snapshot baseline.

---

## 5. Finding and reading the session log

The hooks write a session log to `/tmp/the-rig-session.log`. This is the first place
to look when something isn't behaving as expected.

```bash
# Read the full log
cat /tmp/the-rig-session.log

# Watch it live during a session
tail -f /tmp/the-rig-session.log

# Find the last time the commit sentinel was created or deleted
grep -i "commit\|sentinel" /tmp/the-rig-session.log
```

The log is ephemeral — it doesn't persist across machine reboots. It's written by
`pre-tool.sh`, `post-tool.sh`, and `stop.sh` on every event. Each entry is
timestamped: `[HH:MM:SS] TOOL: what happened`.

---

## 6. CONTEXT_SNAPSHOT.md is missing after a re-clone

**Symptom:** After cloning the project on a new machine (or for a new teammate),
`.rig/memory/CONTEXT_SNAPSHOT.md` doesn't exist and the first session loads all
of PROGRESS.md.

**Why this happens:** `CONTEXT_SNAPSHOT.md` is gitignored — it's machine-local
session state. It never travels with the repo. This is intentional.

**Fix:** Run `/wrap` at the end of the first session on the new machine. It writes
a fresh snapshot reflecting the current project state. Subsequent sessions then
orient from the snapshot instead of loading all of PROGRESS.md.

**For the first session only:** the agent loads PROGRESS.md (last 20 entries) as a
fallback. This is slower but correct. No data is lost.

> **Note:** if you use an external `.rig/` directory (`.rigpath` file in the project
> root), the entire `.rig/` directory is outside the repo and won't clone with it.
> You'll need to re-run the installer on the new machine with `--rig-dir` pointing
> to the same external path, then restore your memory files from a backup or
> another machine.

---

## 7. Hook crashes with "fatal: cannot lock ref" or "index.lock" on Git 2.39+

**Symptom:** A commit fails with a message like:

```
error: cannot lock ref 'HEAD': unable to resolve reference 'HEAD'
fatal: cannot lock ref
```

or:

```
fatal: Unable to create '.../.git/index.lock': File exists.
```

**Cause:** In Git 2.39+, the index is locked for the duration of the commit
operation. If a hook inside that operation calls `git add` to stage a file,
Git tries to acquire a second lock — which fails because the first lock is
still held.

**Fix:** Replace any `git add <file>` calls inside hooks with:

```bash
git update-index --add <file>
```

`git update-index` writes directly to the index without acquiring the full lock,
making it safe to call from within a hook. It accepts `--add` to stage new files,
`--remove` to unstage, and `--chmod=+x` to mark executable bits.

If you're writing a custom hook for this project and need to stage a file, always
use `git update-index --add` instead of `git add`.

---

## Still stuck?

Check the session log first (`/tmp/the-rig-session.log`). If the log shows the hook
firing but the wrong behaviour happening, read the relevant hook script directly —
they're in `.claude/hooks/` and are plain bash.

If something looks like a Rig bug or a missing feature, log it in
`.rig/memory/RIG_GAPS.md` and submit it via `/rig-gaps`.
