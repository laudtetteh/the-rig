# Lessons learned

Seventeen documented pitfalls — from the original LaudBot pilot (#1-#13) through
The Rig's own ongoing development (#14 onward) — the failures that shaped The Rig.

Every component in this system exists because something went wrong without it. These are the incidents, in the order they were discovered.

---

## 1. All edits went into the worktree — invisible to the git client

**Symptom**: Agent completed a full session's worth of work. No changes appeared in Sourcetree, Tower, or any other git client. `git status` in the project root showed a clean working tree.

**Root cause**: Claude Code runs sessions inside hidden git worktrees at paths like `.claude/worktrees/<session-name>/`. All `Write` and `Edit` tool calls targeted the worktree path, not the main repo. From the main repo's perspective, nothing had changed.

**Fix**: Hard rule #11 in `~/.claude/CLAUDE.md` — "Always work in the main repo, not the worktree." Step 0 in `NEW_TASK_WORKFLOW` — confirm working directory with `git rev-parse --show-toplevel` before touching any file. All Write/Edit tool calls must use absolute paths under the main repo root.

**Watch for**: Any time you're not sure where a file is being written. The session log in `/tmp/the-rig-session.log` shows every tool call — check it if something seems off.

---

## 2. pre-tool.sh silently never fired for 30+ PRs

**Symptom**: Pre-tool hook was "installed" and `settings.json` was wired, but protected paths were never blocked. Writes to `.env.production` and `data/approved/` went through without any block message.

**Root cause**: The hook script used `snake_case` tool names (`write_file`, `edit_file`) to check for file writes. Claude Code passes tool names as `PascalCase` (`Write`, `Edit`). The condition `[[ "$TOOL" == "write_file" ]]` never matched anything.

**Fix**: Updated `pre-tool.sh` to check `Write` and `Edit` (PascalCase). Added a comment in the script explicitly warning about this. Verified by checking session logs — logs show the actual tool names being passed.

**Watch for**: Any conditional in hook scripts based on tool names. Always verify against the session log to confirm tool names match expectations.

---

## 3. Secrets appeared in conversation context

**Symptom**: An Anthropic API key was pasted into chat to show an error message. The key was now in conversation context and potentially in Claude's session logs.

**Root cause**: Sharing error output directly that happened to contain a live secret.

**Fix**: Keys were immediately flagged. Both the Anthropic and OpenAI API keys were rotated. Hard rule #4 added: "If a key, token, or password appears in context, redact it immediately, flag it, and prompt the user to rotate it." Pre-commit gitleaks scanning added to prevent secrets from ever reaching the repository.

**Watch for**: Error messages, environment dumps, and log output that may contain secrets. Redact before sharing with the agent.

---

## 4. Task file committed from .rig/tasks/active/ rather than .rig/tasks/done/

**Symptom**: A PR contained both `.rig/tasks/active/TASK_auth.md` (in-progress state) and `.rig/tasks/done/TASK_auth.md` (completed state). The commit history was confusing — a reviewer couldn't tell which state was canonical.

**Root cause**: Task file was staged during the implementation commit before being moved to `done/`.

**Fix**: Explicit staging rule added to `NEW_TASK_WORKFLOW` Step 6 and `SHIP_WORKFLOW`: "Stage the task file only after it has been moved to `.rig/tasks/done/`. Never commit a task file from `.rig/tasks/active/`." The move and the housekeeping commit happen separately from the implementation commit.

**Watch for**: Staging `.rig/tasks/active/` files. Check `git status --short` before committing and verify task files are coming from `.rig/tasks/done/`.

---

## 5. Docker anonymous volume shadowed node_modules after rebuild

**Symptom**: `Module not found` error in the running container after adding a new package. The package appeared in `package.json` and the image rebuilt cleanly, but the running container couldn't find it.

**Root cause**: `docker-compose.yml` declares an anonymous volume (`- /app/node_modules`) to shadow the bind-mounted `node_modules`. Docker named volumes and anonymous volumes are not recreated by `docker compose up --build`. The new image had the package; the running container used the stale anonymous volume.

**Fix**: `docker compose down && docker compose up -d` (recreates the volume on next start) or `docker compose up -d -V` (the `-V` flag forces anonymous volume recreation). Added to `.rig/rules/verification.md` — dependency changes always require verification with a test import in-container.

**Watch for**: Any time you add a dependency and the container is already running. Always run `docker compose up -d -V` after dependency changes, not just `--build`.

---

## 6. PR template compliance drifted silently for 14 PRs

**Symptom**: PRs #16 through #29 all had non-standard structures — wrong section order, missing "Closes" line, missing "Notes" section. Nobody caught it until PR #30.

**Root cause**: No explicit review of the PR template during pre-ship checklist. Once one PR deviated and merged, the next session agent took the previous PR as a model rather than the template.

**Fix**: "Use the PR template exactly" added as an explicit item in `SHIP_WORKFLOW` Step 5. Required sections documented in the checklist. All deviating PRs corrected via GitHub REST API (the `gh` CLI was failing due to a classic projects GraphQL deprecation).

**Watch for**: PR bodies that don't exactly match the five-section template (Summary, Changes, Closes, Test plan, Notes). Check before opening, not after.

---

## 7. gh CLI failed due to GitHub classic projects deprecation

**Symptom**: `gh pr edit` failed consistently with `GraphQL: Projects (classic) is being deprecated... projectCards`. Every attempt to update a PR body via `gh pr edit` exited with code 1.

**Root cause**: The repository was associated with a GitHub classic project. The `gh` CLI uses a GraphQL mutation that includes a deprecated `projectCards` field, which GitHub now rejects.

**Fix**: Used the GitHub REST API directly: `curl -X PATCH https://api.github.com/repos/[owner]/[repo]/pulls/[N] -H "Authorization: Bearer $TOKEN" -d '{"body": "..."}'`. Token retrieved via `gh auth token`. Returned 200 for all updated PRs.

**Watch for**: Any `gh pr edit` call. If the repo is associated with a classic project, use the REST API via curl instead.

---

## 8. Migration table name typo took production down

**Symptom**: Application crashed on startup in production with `UndefinedTableError` on every request. The table existed in the database but the application couldn't find it.

**Root cause**: Migration file created a table named `mode_configs` (plural). Application code queried `mode_config` (singular). One character difference. Migrations run on startup — the mismatch surfaced immediately in production but was never caught locally because the local database had been reset.

**Fix**: `.rig/rules/verification.md` updated — migrations explicitly require in-container verification before committing. The smoke test must include a query against the new table to confirm the name matches what the application expects.

**Watch for**: Any migration that creates a table or column referenced by application code. Always verify the exact name matches at both ends before committing.

---

## 9. FastAPI routes with status_code=204 crash at import

**Symptom**: Backend refused to start with a `ValueError` at import time — before serving a single request. Error pointed to a route decorated with `@router.get(...)` and `status_code=204`.

**Root cause**: FastAPI validates route definitions at module load time. A route with `status_code=204` (No Content) must also explicitly declare `response_model=None`. If omitted, FastAPI raises at startup, not at request time — so the error surfaces in production even if the route is never called.

**Fix**: Added `response_model=None` to all `204` routes. Logged in `ERRORS.md`. Pattern documented in `.rig/rules/coding-standards.md`.

**Watch for**: Any route that returns 204. Always pair `status_code=204` with `response_model=None`. The error message when this is missing is not intuitive — it points to the module, not the route.

---

## 10. Moving the project directory broke Claude Code hooks silently

**Symptom**: Pre-tool and post-tool hooks stopped firing after renaming or moving the project directory. No error was shown — file writes to protected paths went through without any block message.

**Root cause**: `install.sh` bakes the absolute project path into `.claude/settings.json` at install time via the `[REPO_ROOT]` placeholder substitution. The hook commands look like `bash /Users/you/projects/old-name/.claude/hooks/pre-tool.sh`. After a move or rename, that path no longer exists — the hook script silently fails to launch, and Claude Code treats this as a passing hook (exit 0 by default).

**Fix**: Re-run the installer after moving the project:
```bash
cd the-rig && ./install.sh --project-only
```
Choose **Overwrite** or **Merge** strategy. The installer will substitute the new absolute path into `settings.json`.

Alternatively, edit `.claude/settings.json` directly and update the hook command paths to the new location.

**Watch for**: Any time you rename, move, or reorganize a project directory where The Rig is installed. Check `/tmp/the-rig-session.log` — if hooks are firing, you'll see timestamped `PRE` entries. If the log is empty or stale, hooks aren't running.

---

## 11. useSearchParams() broke the standalone Next.js build

**Symptom**: `next build` completed successfully in development. The production standalone build failed with a static generation error pointing to a page that used `useSearchParams()`.

**Root cause**: Next.js standalone output mode (`output: 'standalone'`) statically pre-renders pages at build time. `useSearchParams()` is a dynamic hook that reads from the URL at runtime. Mixing them on the same component causes a static generation failure — but only in the production build, not in `next dev`.

**Fix**: Split the affected page into an inner component (which uses `useSearchParams`) and an outer page component that wraps the inner component in `<Suspense>`. The `<Suspense>` boundary tells Next.js that the inner component's rendering is deferred.

**Watch for**: Any Next.js page in a standalone build that uses `useSearchParams`, `usePathname` with dynamic params, or any other hook that reads runtime URL state. The error only surfaces in production builds — test with `next build && next start`, not just `next dev`.

---

## 12. The Merge strategy silently left Rig-owned files stale on upgrade

**Symptom**: After pulling a new version of The Rig and re-running the installer with Merge strategy, all the freshly updated hook scripts and slash commands were still the old versions. No error was shown — the installer simply skipped them because they already existed at the destination.

**Root cause**: Merge strategy (`COLLISION_STRATEGY=merge`) is designed for initial drop-in installs: it skips any file that already exists and only smart-merges `settings.json`. This is correct behavior for a first install. But it's wrong for an upgrade — Rig-owned files like `pre-tool.sh`, `post-tool.sh`, and process files need to be updated when The Rig ships new versions.

**Fix**: The installer now has a dedicated **Upgrade** strategy (option 5). It classifies every file as Rig-owned or user-owned. Rig-owned files (hooks, commands, processes, Husky scripts) are auto-updated when unmodified, or shown a diff with a prompt when customized. User-owned files (CLAUDE.md, rules/, memory/, tasks/, .github/) are always skipped. The Upgrade strategy records a SHA256 manifest at install time so it can detect your customizations on the next run.

The manifest was later extended (v1.10.0) to track **all** files — not just Rig-owned ones. This means the Upgrade strategy can now also detect customizations to user-owned files and protect them, rather than silently skipping all of them. The overwrite strategy received the same manifest-awareness: it warns before touching any user-customized file.

**Watch for**: Never use Merge strategy to upgrade an existing install — only use it for the initial drop-in. When upgrading, always choose Upgrade (5). See `docs/customizing.md` for the full upgrade workflow.

---

## 13. Task files and PRs described the plan rather than the actual outcome

**Symptom**: A merged PR's description read like a planning document. The `## Done notes` section in the task file was either blank or restated the `## Approach` verbatim. Reviewers couldn't tell what actually shipped, and future sessions couldn't learn from scope changes that happened during implementation.

**Root cause**: No explicit distinction was enforced between planning artifacts and outcome records. `## Approach` (the plan) and `## Done notes` (what happened) served the same purpose in practice — both ended up describing intent.

**Fix**: `## Done notes` now has four required fields: **What was built** (specific implementation), **Deviations from plan** (where scope or approach changed and why), **Actual files touched** (anything not in the original plan), and **Follow-ups opened** (new tasks or issues created as a result). `NEW_TASK_WORKFLOW` Step 7 requires a plan-vs-reality audit before the task file is moved. `SHIP_WORKFLOW` Step 4 requires the same check, and Step 5 explicitly states the PR body must describe what was actually built.

**Watch for**: Any `## Done notes` section that reads like a summary of `## Approach`. If they say the same thing, the done notes haven't been filled in properly. The PR body and the GitHub Issue closing comment have the same requirement — they capture the actual outcome, not the original intent.

---

## 14. A months-old, already-fixed bug had silently overwritten CLAUDE.md on two real projects, undetected until a post-upgrade content audit

**Symptom**: After running `agent-upgrade` against 10 real, independently-installed Rig projects and bringing them to 1.24.0, a routine post-upgrade `git diff` on the two repo-tracked targets showed `CLAUDE.md` (and, for one, `PROJECT_BRIEF.md`) as modified — with real, hand-written project descriptions replaced by blank `[PLACEHOLDER]` template text. Both the JSON self-report from today's `agent-upgrade` run and the file's own `git log` showed today's run never touched the file at all: the blank content had been sitting there, uncommitted, for months before this session started.

**Root cause**: v1.10.0 (May 2026) briefly shipped a regression where `_copy_file_upgrade` treated a missing manifest entry as "unmodified since install — safe to overwrite," with no split for user-owned files. Any project upgraded during that narrow window had `CLAUDE.md`/`PROJECT_BRIEF.md` silently reset to the raw template. This was fixed three days later in v1.10.1 (commit `28b8756`, issue #140) — but the fix only prevents *future* overwrites; it does nothing to repair damage a project already took during the buggy window, and any project that wasn't upgraded again afterward would carry the corruption indefinitely. On the two affected projects here, `CLAUDE.md` had never been re-committed since its original scaffold commit, so the corrupted content sat as an uncommitted, invisible-to-`git status`-until-you-look-at-it change — nobody happened to open `git diff` on that specific file for months.

**Fix**: Restored both files via `git checkout --` (git had the real content the entire time, since the corrupted state was never committed). No code change was needed — the underlying bug was already fixed in v1.10.1. Filed and fixed a related but separate issue found during the same audit: `bin/rig doctor`'s `manifest_mode_hash`/`stale_manifest_entries` gates resolved every manifest path against the project root unconditionally, false-failing on every stealth install (#468, PR #469).

**Watch for**: A project that goes long stretches between `/rig-upgrade` runs can carry silent damage from a bug that was fixed upstream ages ago — the fix only stops new damage. For any git-tracked project, a routine `git diff`/`git status` after an upgrade is real protection. **For stealth/external installs, `CLAUDE.md` and `PROJECT_BRIEF.md` are git-excluded by design — there is no diff to catch this, and if no `.rig-backup/` snapshot predates the damage, content lost this way is unrecoverable.** Three stealth-mode files initially looked like further instances of this same bug (`scrap`'s `CLAUDE.md`+`PROJECT_BRIEF.md`, `beaconessentials-main`'s `PROJECT_BRIEF.md`) but turned out, on full-file inspection, to be pristine unfilled templates in every section — consistent with never having been filled in rather than destroyed. Don't conclude "bug damage" from one blank section alone; check whether the rest of the file is genuinely customized first.

---

## 15. A symlink-refusal fix only actually worked under one of seven install strategies, undetected by 585+ passing tests

**Symptom**: `/rig-surface-review`'s (see `docs/decisions.md` #20) first ever real end-to-end run, dispatched against the `chore/1.24.0-retro-audit` branch with no specific bug to chase, flagged that a git-hook symlink-refusal fix already on the branch (issue #451: "a symlinked git hook destination is refused, never silently destroys its target") might not actually apply outside `--strategy upgrade`. Reproduced directly against a live checkout: a fresh `--strategy merge` install (the default for every new project), followed by symlinking `.git/hooks/pre-commit` to a file outside the project, followed by a second `--strategy merge` run, printed `⚠ customized or unrecognized git hook detected... A backup will be saved to .rig-backup/...` and then silently overwrote the symlink's *target* file's content in place anyway — zero backup ever created.

**Root cause**: The #451 fix routed `_stealth_install_git_hook()`'s protection check through `upgrade_prepare_mutation()`, a shared helper whose very first line is `[[ "$COLLISION_STRATEGY" == upgrade ]] || return 0` — by design, since its other ~13 callers are genuinely upgrade-only operations (settings merges, `.rigpath`, `.rig/VERSION`, etc.). Git-hook installation is not upgrade-only — it needs to happen, and be protected, under every strategy, including `merge` (the default for a fresh install). Routing it through an upgrade-only guard silently no-opped the entire check for four of the seven `--strategy` values (`merge`, `skip`, `overwrite`, `interactive` all set `COLLISION_STRATEGY` to their own name, never `upgrade`) — only `upgrade`, `agent-plan`, and `agent-upgrade` satisfy the guard, the latter two because they internally force `COLLISION_STRATEGY="upgrade"` regardless of their own flag name. This was invisible to extensive `agent-plan`/`agent-upgrade` testing for exactly that reason — including a prior holistic combinatorial review that reported zero findings, since none of it ever actually exercised the vulnerable path. The regression test added alongside the original #451 fix also only covered `--strategy upgrade`, since the test file's own shared helper hardcodes that strategy.

**Fix**: Extracted the state-check/backup/refuse logic into a new strategy-agnostic `guard_destination_before_write()`, leaving `upgrade_prepare_mutation()` as a thin upgrade-only wrapper around it — verified byte-identical for its other callers by diffing the extracted body against the original. `_stealth_install_git_hook()` now calls the unconditional guard directly. Added a regression test that repeats the existing symlink-refusal test under `--strategy merge` explicitly, proven via revert against the pre-fix code.

**Watch for**: A fix routed through a shared helper inherits that helper's own scoping assumptions, which may not match the new call site's actual requirements — "this function already does the safety check I need" is not the same claim as "this function performs that check under every condition my call site can be reached from." Independent review — including this session's own prior whole-branch review and holistic combinatorial-matrix pass, both of which reported zero findings on this exact branch — is not a substitute for actually exercising the default, most-common invocation path (`merge`, no flags) rather than only the paths a reviewer's own test scenarios happen to reach. Two more instances of the identical bug class (notification-helper and Codex-config writes, reachable via `--notifications`/`--project-agent codex` under `merge`) were found in the same review pass and filed separately (#477) rather than fixed immediately, since they were outside this specific commit's claimed scope.

---

## 16. `bin/rig` at the installer repo's own root is a stale dev-tooling copy, not the shipped source

**Symptom**: While implementing issue #473's new `bin/rig doctor` checks, every live test against a real target project reported "no pre-flight snapshot found" even when one genuinely existed. Syntax was clean, the logic traced correctly on paper — the checks simply weren't running against the file that mattered.

**Root cause**: This repo dogfoods itself, and `bin/rig` exists in two places that can silently diverge: the repo root's own copy (untracked, `.git/info/exclude`d, part of this repo's own stealth-mode dev tooling, refreshed via `bin/rig worktree bootstrap` from whichever checkout happens to be primary) and `templates/project/bin/rig` (tracked, the actual file copied into every downstream project on install/upgrade). All the implementation and testing had gone into the untracked root copy — confirmed after the fact to have different byte counts and different code from the tracked template it was assumed to be identical to.

**Fix**: Restored the accidentally-edited root copy from the primary checkout, reapplied the real fix to `templates/project/bin/rig`, and re-validated by installing that file into a real throwaway target project (the only way `bin/rig`'s own root-resolution logic correctly points at a target project rather than back at the installer's own worktree).

**Watch for**: Before editing `bin/rig` for any reason, confirm which copy you're looking at with `git ls-files bin/rig templates/project/bin/rig` — the working file's presence or absence in that output is definitive. `git status --short bin/rig` showing nothing at all, even immediately after an edit, is itself the tell that you're looking at the untracked dev copy rather than the shipped source.

---

## 17. A `-t 0` guard added "for consistency with its neighbors" broke a call site whose lack of that guard was itself load-bearing

**Symptom**: Fixing issue #476's `--target` path prompt by adding a `[[ -t 0 && -z "$AGENT_MODE" ]]` guard — matching the pattern already used on the neighboring `--project-name` and base-branch prompts in the same code region — passed its own new regression tests but broke an existing, previously-green test (`tests/test_install.bats`, "stealth mode: warns when .husky/ exists in target project").

**Root cause**: That test drives the interactive installer non-interactively by piping its answers through a heredoc (`<<<`) — not a real TTY. It depended on the `--target` prompt's original, guard-free behavior of always attempting to read from stdin regardless of TTY-ness; unlike its sibling prompts, this one had never had a `-t 0` check at all, and that absence was load-bearing. Adding `-t 0` made the non-tty heredoc skip the read and silently default to `$(pwd)` instead, which desynchronized every subsequent piped answer in the test — the tracking-menu's own read then consumed the string meant for a different prompt entirely.

**Fix**: Reverted to `[[ -z "$AGENT_MODE" ]]` alone, with no `-t 0` component, for this one call site. That's both necessary and sufficient: it still closes the actual hang (agent-plan/agent-upgrade unconditionally skip the prompt regardless of stdin), and a plain `read` on non-agent, non-tty stdin — closed, `/dev/null`, or a heredoc — never blocks; it just returns immediately.

**Watch for**: Several similar-looking guards sitting near each other in a script does not mean they should all be normalized to the identical pattern. Before "fixing" one to match its neighbors, check what its *current* behavior is actually depended on — via existing tests, not just by reading the code — since the neighbors' guards may already be safe for reasons this particular call site isn't.
