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

**Symptom:** Protected structured writes are not blocked, or commits do not
require approval and never auto-stub PROGRESS.md.

**Causes and fixes:**

### Hooks not executable
After a re-clone or a manual copy, hook scripts can lose their executable bit.
The Claude Code adapter ships up to nine hook scripts in `.claude/hooks/`:
`pre-tool.sh`, `post-tool.sh`, `permission-request.sh`, `prompt-submit.sh`,
`session-start.sh`, `stop.sh`, `pre-compact.sh`, `post-compact.sh`, and
`subagent-start.sh` (the last only with `--subagents` or a Codex project target).
Restore the bit on every installed hook rather than a subset:

```bash
chmod +x .claude/hooks/*.sh
# Codex project target:
chmod +x .codex/hooks/rig-adapter.sh
# Git hooks — repo, local, or external tracking:
chmod +x .husky/pre-commit .husky/commit-msg .husky/post-commit .husky/post-merge
# Git hooks — stealth tracking (installed into .git/hooks/ instead of .husky/):
chmod +x .git/hooks/pre-commit .git/hooks/commit-msg .git/hooks/post-commit .git/hooks/post-merge
```

Re-running the project installer also sets the executable bit on
`.claude/hooks/`, `.codex/hooks/`, and `.husky/` scripts (an upgrade leaves a
skipped customized file's mode alone). In stealth tracking, `.git/hooks/` files
get the bit when the installer writes them.

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

**Symptom:** A guarded `git commit` reports missing or stale approval even though you
already said the trigger phrase. Or the sentinel file (`.rig-commit-ok`) exists but
the commit still fails.

**Causes and fixes:**

### Stale sentinel from a failed commit
If a previous commit failed before `commit-msg` ran, the sentinel may remain.
If `commit-msg` ran, it consumed approval for that attempt. In a hookless
install, PreToolUse consumes approval before the visible commit runs.
After resolving merge conflicts, a guarded `git commit` is a new approved
attempt even while `MERGE_HEAD` exists. A guarded `git merge --no-ff` that
creates a commit also needs approval before it starts.

The sentinel lives in the effective Rig directory: `.rig/` for repo or local
tracking, or the directory named in `.rigpath` for stealth or external tracking.

```bash
# Resolve the effective Rig directory
RIG_DIR="$(python3 bin/rig-path.py "$PWD")" || exit 1

# Check if it exists
ls "$RIG_DIR/memory/.rig-commit-ok"

# Delete it and start the commit flow again
rm "$RIG_DIR/memory/.rig-commit-ok"
```

### Git hooks are not installed or enabled
Check `git config --get core.hooksPath` and the executable `commit-msg` and
`post-commit` files in the active hook directory. `--skip-git-hooks` omits native
hook installation. With no active Rig `commit-msg`, a visible guarded agent
commit uses the limited PreToolUse gate: fresh approval, branch, and direct-push
type are checked before approval is consumed. PostToolUse stubs progress when
it sees a matching successful Git result; quiet output or opaque scripts may
leave no stub. With a compatible `commit-msg` but no working `post-commit`,
the same visible PostToolUse fallback can log the commit once from its final SHA.
An executable `commit-msg` that lacks Rig's guarded policy is
treated as incompatible and blocks the visible guarded command. PreToolUse
checks compatibility with a dedicated `--rig-policy-probe` hook argument;
custom wrappers must handle it without side effects before normal message-file
handling and delegate the real commit invocation.
Explicit `--no-verify`, `core.hooksPath` overrides, and `HUSKY=0` in visible agent
commands are blocked by PreToolUse, though dynamically assembled commands can
still bypass static detection.

### Running git commit outside Claude Code
Ordinary terminal commits without `RIG_COMMIT_POLICY=guarded` retain format and
ticket checks but do not require the one-use approval. Agent commit commands
must set the marker and create fresh approval in the current worktree's
`.rig/memory` or the directory named by its `.rigpath`.

### Codex hooks or generated skills are missing

Codex uses `.codex/hooks.json` plus `.codex/hooks/rig-adapter.sh`, and receives
workflow skills generated under `.agents/skills/`. Check the persisted project
target and run the provider-neutral doctor before inspecting individual files:

```bash
RIG_DIR="$(python3 bin/rig-path.py "$PWD")" || exit 1
bin/rig doctor --json
cat "$RIG_DIR/install-targets.json" 2>/dev/null || true
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

## 4. PROGRESS.md is too large / session start is slow

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
`$RIG_DIR/memory/PROGRESS_archive.md`, where `$RIG_DIR` is `.rig/` for repo or
local tracking and the `.rigpath` target for stealth or external tracking. If the
cap hasn't been hit yet (under 20 entries) but startup is still slow, the issue
is likely a missing or stale snapshot — see "CONTEXT_SNAPSHOT.md is missing" and
"CONTEXT_SNAPSHOT.md is stale" in this section.

To manually trim if `/wrap` hasn't been run recently:
```bash
RIG_DIR="$(python3 bin/rig-path.py "$PWD")" || exit 1
# Count entries
grep -c "^## " "$RIG_DIR/memory/PROGRESS.md"
# Then run /wrap; it archives entries beyond 20 automatically
```

---

## 5. /wrap suggests the wrong session name

**Symptom:** `/wrap` suggests a name containing work from another session or
omitting work from the current one.

**Cause:** The current conversation or exact session record was resolved
incorrectly, or evidence from another session entered the suggestion.

**How naming works:** The current conversation is authoritative. `/wrap` resolves
the exact active Rig session and may cross-check only PROGRESS entries tagged with
that session's UUID and a compact checkpoint with the matching anchor. Legacy
`<!-- session-end -->` ranges and snapshot dates are housekeeping signals, not
naming boundaries.

**Fixes:**

- Check `bin/rig session current --json` and `bin/rig session doctor --json` for
  unresolved identity or ambiguous records. Repair the reported identity problem
  before completing a session record.
- Compare the proposed name with work actually done in this conversation. Discard
  unrelated PROGRESS entries, checkpoints, and project history as naming evidence.
- If exact recovery is unavailable, `/wrap` may refresh shared project memory
  and `CONTEXT_SNAPSHOT.md` but skips final session-record mutation. Ambiguous,
  duplicate, malformed, or unsafe records stop the write workflow entirely.
  Pruning markers or changing a snapshot date will not repair session identity.

---

## 6. Finding and reading the session log

The hooks write a project-qualified session log to
`/tmp/the-rig-session-<project>.log` by default. Set `RIG_SESSION_LOG` to override
that path. This is the first place to look when a hook misbehaves.

```bash
# Resolve the same default path used by the hooks, unless overridden
REPO=$(git rev-parse --show-toplevel)
SESSION_LOG=${RIG_SESSION_LOG:-/tmp/the-rig-session-$(basename "$REPO").log}

# Read the full log
cat "$SESSION_LOG"

# Watch it live during a session
tail -f "$SESSION_LOG"

# Find the last time the commit sentinel was created or deleted
grep -i "commit\|sentinel" "$SESSION_LOG"
```

The log is ephemeral — it doesn't persist across machine reboots. It's written by
`pre-tool.sh`, `post-tool.sh`, and `stop.sh` on every event. Each entry is
timestamped: `[HH:MM:SS] TOOL: what happened`.

---

## 7. CONTEXT_SNAPSHOT.md is missing after a re-clone

**Symptom:** After cloning the project on a new machine (or for a new teammate),
`CONTEXT_SNAPSHOT.md` doesn't exist in the effective Rig directory's `memory/`
folder and the first session loads all of PROGRESS.md.

**Why this happens:** `CONTEXT_SNAPSHOT.md` is gitignored — it's machine-local
session state. It never travels with the repo. This is intentional.

**Fix:** Run `/wrap` at the end of the first session on the new machine. It writes
a fresh snapshot reflecting the current project state. Subsequent sessions then
orient from the snapshot instead of loading all of PROGRESS.md.

**For the first session only:** the agent loads PROGRESS.md (last 20 entries) as a
fallback. This is slower but correct. No data is lost.

> **Note:** with stealth or external tracking, the Rig directory lives outside the
> repo and `.rigpath` is excluded through `.git/info/exclude`, so neither clones
> with the project. Restore the Rig directory from a backup, sync, or another
> machine, then re-run the installer with the same `--tracking` mode and a
> `--rig-dir` pointing at the restored directory.

---

## 8. Hook crashes with "fatal: cannot lock ref" or "index.lock" on Git 2.39+

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

## 9. "Commit to 'main' blocked by The Rig"

**Symptom:** A guarded agent commit (`RIG_COMMIT_POLICY=guarded git commit ...`)
on `main` or `master` fails with one of these messages from the Rig `commit-msg`
hook:

```
ERROR: Commit to 'main' blocked by The Rig; create a feature branch.
```

```
ERROR: Direct-to-main commit blocked; only chore/docs subjects are allowed.
```

When no Rig `commit-msg` hook is active, the PreToolUse commit gate prints the
same text prefixed with `Blocked:` instead of `ERROR:`.

**Cause:** Both guards check guarded commits whose current branch is literally
`main` or `master`. The `commit-msg` guard skips commits Git creates while
replaying history (rebase, cherry-pick, revert, or another sequencer run).
For other guarded commits on those branches:

- Without `housekeeping: direct-push` in the project `CLAUDE.md`, every guarded
  direct commit is blocked with the first message.
- With `housekeeping: direct-push`, a guarded direct commit is allowed only when
  its subject is a `chore` or `docs` Conventional Commit (for example
  `chore(rig): log session progress`). Any other type, such as `feat` or `fix`,
  is blocked with the second message.

Ordinary terminal commits without `RIG_COMMIT_POLICY=guarded` are not checked by
this guard. The `commit-msg` hook consumes the one-use approval before its branch
check, so an attempt it blocks needs fresh approval before retrying; the
PreToolUse gate checks the branch before consuming approval.

**Fix for feature branch projects:** this is the correct behavior. Create a branch
before committing:

```bash
git checkout -b feat/your-change
```

**Fix for solo or housekeeping projects** that legitimately commit housekeeping
changes directly to `main` (e.g. post-merge memory updates): make sure your
project's `CLAUDE.md` contains this line. The scaffolded `CLAUDE.md` ships with
it, so it is only missing if it was removed or changed:

```
housekeeping: direct-push
```

This setting permits direct guarded commits only for `chore` and `docs`
subjects. Feature and fix work still needs a branch. To block every guarded
direct commit, set `housekeeping: pr-required` instead.

---

## Case-only branch rename says the branch already exists

**Symptom:** Renaming a branch only to change capitalization (for example,
`feat-241` to `FEAT-241`) reports that the target branch already exists.

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

Check the session log first (see the project-qualified path in section 6). If the log shows the hook
firing but the wrong behaviour happening, read the relevant hook script directly —
they're in `.claude/hooks/` and are plain bash.

If something looks like a Rig bug or a missing feature, log it in
`$RIG_DIR/memory/RIG_GAPS.md` (`.rig/` for repo or local tracking, the `.rigpath`
target for stealth or external tracking) and submit it via `/rig-gaps`.
