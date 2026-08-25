# Troubleshooting

> Coexistence: first identify whether the failing surface is shared, Claude Code-specific, or Codex-specific. Provider hook/configuration diagnostics are not interchangeable; shared `.rig` state remains the common source of truth.

Common problems and how to fix them.

---

## 0. First: run the status adapter

Before digging into a specific problem, run Claude `/rig-status` or Codex
`$rig-status`. It checks hook files, memory files, provider wiring, and pending flags in one
pass — and prints a ✓/✗ report with fix hints for anything broken.

```
/rig-status   # Claude Code
$rig-status   # Codex
```

If the output is clean (0 issues), the problem is likely in how the agent
is interpreting instructions, not in the installation. Proceed to the
sections below for specific symptoms.

---

## 1. A completed upgrade needs to be undone

**Symptom:** An upgrade finished and wrote changes, but review shows you need to
return the Rig-managed files to their pre-upgrade state.

First inspect the rollback plan:

```bash
bin/rig upgrade rollback --last --dry-run
```

If the plan is correct, confirm with the rollback id printed by the dry run:

```bash
bin/rig upgrade rollback --id <rollback_id> --confirm <rollback_id>
```

Rollback is for completed upgrades that wrote a durable report under
`upgrade-reports/`. If the installer was interrupted before completion, use
`install.sh --recover` instead.

---

## 2. Hooks aren't firing

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

## 3. Commit gate is blocking unexpectedly

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

### Codex hooks or generated skills are missing

Codex uses `.codex/hooks.json` plus `.codex/hooks/rig-adapter.sh`, and receives
workflow skills generated under `.agents/skills/`. Check the persisted project
target and run the provider-neutral doctor before inspecting individual files:

```bash
bin/rig doctor --json
cat .rig/install-targets.json 2>/dev/null || true
test -x .codex/hooks/rig-adapter.sh
test -d .agents/skills
```

An installed Codex CLI or a present `.codex/config.toml` proves installation or
configuration only. It does not prove that a current session can see or call a
tool. Use the session-native connector preflight when a workflow depends on MCP
or app tools.

### Claude and Codex behave differently for the same workflow

Treat `.rig/processes/` as canonical. Claude `/name` commands and Codex `$name`
skills are delivery adapters. Re-run the installer with `--strategy upgrade` to
regenerate Codex skills from the canonical command sources; do not patch a
generated `.agents/skills/` file independently.

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

## 8. "Commit to 'main' blocked by The Rig"

**Symptom:** The agent tries to commit and receives:

```
Commit to 'main' blocked by The Rig.
Committing directly to 'main' is not allowed.
Create a feature branch first: git checkout -b feat/your-description
```

**Cause:** The main-branch commit guard in `pre-tool.sh` blocks all direct commits
to `main` or `master` unless the project explicitly allows them.

**Fix for feature branch projects:** this is the correct behavior. Create a branch
before committing:

```bash
git checkout -b feat/your-change
```

**Fix for solo or housekeeping projects** that legitimately commit directly to `main`
(e.g. post-merge housekeeping commits): add this line to your project's `CLAUDE.md`:

```
housekeeping: direct-push
```

This setting tells the guard that direct commits are intentional for this project.
It is already set in The Rig's own `CLAUDE.md` as it uses direct-push for
housekeeping commits.

---

## Case-only branch rename says the branch already exists

**Symptom:** Renaming a branch only to change capitalization (for example,
`bweb-241` to `BWEB-241`) reports that the target branch already exists.

**Cause:** On a case-insensitive filesystem, a direct `git branch -m` can resolve
the old and new spellings to the same ref path.

**Fix:** Use `/task` or `/ship`'s branch rename helper. It moves the branch through
a collision-checked `tmp/<slug>-rename` ref and then to the desired spelling. If the
second move fails, it attempts to restore the original name and reports any retained
temporary ref. A rename to a genuinely different existing branch remains an error.

---

## `gh` uses the wrong account or reports unexpected authentication failures

**Symptom:** `gh` uses a different account than `gh auth status` shows as active,
or a command fails even though the expected account is logged in through the
system keychain.

**Cause:** An inherited `GH_TOKEN` or `GITHUB_TOKEN` environment variable takes
precedence over stored credentials. A stale token can therefore shadow the account
selected in the keychain. Check whether either variable is set without printing its
value:

```bash
env | grep -E '^(GH_TOKEN|GITHUB_TOKEN)=' >/dev/null \
  && echo "A GitHub token variable is set"
```

**Fix:** Remove both variables from the current shell, select the intended stored
account, and identify the repository explicitly when the working directory or
remote could be ambiguous:

```bash
unset GH_TOKEN GITHUB_TOKEN
gh auth switch --user YOUR_GITHUB_LOGIN
gh issue list --repo owner/name
```

For a single command, remove the variables only from that command's environment:

```bash
env -u GH_TOKEN -u GITHUB_TOKEN gh issue list --repo owner/name
```

If the token variables return in a new shell, remove or update the exports in your
shell profile, environment manager, or parent process.

---

## Yarn 4 aborts because `YARN_NO_PROXY` maps to legacy `noProxy`

**Symptom:** A Yarn 4 command exits during configuration loading and reports that
`noProxy` is an unrecognized or legacy configuration setting.

**Cause:** Yarn converts inherited `YARN_*` environment variables into Yarn
configuration keys. `YARN_NO_PROXY` becomes the legacy `noProxy` key, so Yarn can
abort before it runs the requested script. This variable is often inherited from a
shell profile, proxy setup, IDE, or parent process rather than from the project.

**Fix:** Remove `YARN_NO_PROXY` from the Yarn command's environment:

```bash
env -u YARN_NO_PROXY yarn <script>
```

For example:

```bash
env -u YARN_NO_PROXY yarn test
```

If that works, remove or scope the `YARN_NO_PROXY` export at its source. Unsetting
only this variable preserves other proxy variables that unrelated tools may need.

---

## Still stuck?

Check the session log first (`/tmp/the-rig-session.log`). If the log shows the hook
firing but the wrong behaviour happening, read the relevant hook script directly —
they're in `.claude/hooks/` and are plain bash.

If something looks like a Rig bug or a missing feature, log it in
`.rig/memory/RIG_GAPS.md` and submit it via `/rig-gaps`.
