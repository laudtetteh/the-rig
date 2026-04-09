# Lessons learned

Ten documented pitfalls from the LaudBot pilot — the failures that shaped The Rig.

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

## 4. Task file committed from tasks/active/ rather than tasks/done/

**Symptom**: A PR contained both `tasks/active/TASK_auth.md` (in-progress state) and `tasks/done/TASK_auth.md` (completed state). The commit history was confusing — a reviewer couldn't tell which state was canonical.

**Root cause**: Task file was staged during the implementation commit before being moved to `done/`.

**Fix**: Explicit staging rule added to `NEW_TASK_WORKFLOW` Step 6 and `SHIP_WORKFLOW`: "Stage the task file only after it has been moved to `tasks/done/`. Never commit a task file from `tasks/active/`." The move and the housekeeping commit happen separately from the implementation commit.

**Watch for**: Staging `tasks/active/` files. Check `git status --short` before committing and verify task files are coming from `tasks/done/`.

---

## 5. Docker anonymous volume shadowed node_modules after rebuild

**Symptom**: `Module not found` error in the running container after adding a new package. The package appeared in `package.json` and the image rebuilt cleanly, but the running container couldn't find it.

**Root cause**: `docker-compose.yml` declares an anonymous volume (`- /app/node_modules`) to shadow the bind-mounted `node_modules`. Docker named volumes and anonymous volumes are not recreated by `docker compose up --build`. The new image had the package; the running container used the stale anonymous volume.

**Fix**: `docker compose down && docker compose up -d` (recreates the volume on next start) or `docker compose up -d -V` (the `-V` flag forces anonymous volume recreation). Added to `rules/verification.md` — dependency changes always require verification with a test import in-container.

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

**Fix**: `rules/verification.md` updated — migrations explicitly require in-container verification before committing. The smoke test must include a query against the new table to confirm the name matches what the application expects.

**Watch for**: Any migration that creates a table or column referenced by application code. Always verify the exact name matches at both ends before committing.

---

## 9. FastAPI routes with status_code=204 crash at import

**Symptom**: Backend refused to start with a `ValueError` at import time — before serving a single request. Error pointed to a route decorated with `@router.get(...)` and `status_code=204`.

**Root cause**: FastAPI validates route definitions at module load time. A route with `status_code=204` (No Content) must also explicitly declare `response_model=None`. If omitted, FastAPI raises at startup, not at request time — so the error surfaces in production even if the route is never called.

**Fix**: Added `response_model=None` to all `204` routes. Logged in `ERRORS.md`. Pattern documented in `rules/coding-standards.md`.

**Watch for**: Any route that returns 204. Always pair `status_code=204` with `response_model=None`. The error message when this is missing is not intuitive — it points to the module, not the route.

---

## 10. useSearchParams() broke the standalone Next.js build

**Symptom**: `next build` completed successfully in development. The production standalone build failed with a static generation error pointing to a page that used `useSearchParams()`.

**Root cause**: Next.js standalone output mode (`output: 'standalone'`) statically pre-renders pages at build time. `useSearchParams()` is a dynamic hook that reads from the URL at runtime. Mixing them on the same component causes a static generation failure — but only in the production build, not in `next dev`.

**Fix**: Split the affected page into an inner component (which uses `useSearchParams`) and an outer page component that wraps the inner component in `<Suspense>`. The `<Suspense>` boundary tells Next.js that the inner component's rendering is deferred.

**Watch for**: Any Next.js page in a standalone build that uses `useSearchParams`, `usePathname` with dynamic params, or any other hook that reads runtime URL state. The error only surfaces in production builds — test with `next build && next start`, not just `next dev`.
