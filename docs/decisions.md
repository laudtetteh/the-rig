# Key design decisions

Why The Rig is built the way it is. Each entry covers what was decided, what was rejected, and the tradeoff accepted.

---

## 1. Two-layer architecture (global + project) rather than one big CLAUDE.md

**Decided:** Split into a global layer (`~/.claude/`) and a project layer (repo root).

**Rejected:** A single monolithic CLAUDE.md in every project, or a single global file for everything.

**Rationale:** The global layer contains things that are universally true: hard rules, working style, memory discipline, personal context. These don't belong in a project repo — they'd need to be duplicated across every project, drift out of sync, and would expose personal context in public repos. The project layer contains things specific to this codebase: stack, conventions, off-limits paths. The separation is clean because each layer has a distinct lifecycle (global = evolves slowly; project = evolves with the codebase).

**Tradeoff accepted:** Two places to maintain instead of one. Accepted — the separation is worth it.

---

## 2. Memory files over relying on conversation history

**Decided:** Persistent memory via `PROGRESS.md`, `ERRORS.md`, and `CONTEXT_SNAPSHOT.md`.

**Rejected:** Expecting agents to scroll back through chat history for context.

**Rationale:** Claude Code sessions are stateless — context resets between sessions. Even within a long session, context compaction summarizes conversation history, losing nuance. Three focused files are faster to read, more durable, and more reliable than any conversation artifact. `CONTEXT_SNAPSHOT.md` is designed specifically as a session-handoff document: overwritten at session end, read at session start.

**Tradeoff accepted:** The agent must be disciplined about updating these files. The `post-tool.sh` hook partially automates `PROGRESS.md` (auto-stub after commits) to reduce the discipline requirement.

---

## 3. CONTEXT_SNAPSHOT.md is gitignored

**Decided:** Session state lives on disk only, never committed.

**Rejected:** Committing `CONTEXT_SNAPSHOT.md` to the repo.

**Rationale:** It's session state, not project history. It would create noise PRs on every session close. It would go stale the moment a branch diverges from main. It may contain sensitive environment notes, in-flight decision details, or personal context that doesn't belong in version control. History belongs in `PROGRESS.md`. The snapshot is purely for session continuity — it belongs on the local machine.

**Tradeoff accepted:** The snapshot is not synced across machines. Acceptable — Claude Code sessions are single-machine.

---

## 4. Hooks enforce what rules document

**Decided:** Use Claude Code's `PreToolUse` hook to physically block writes to protected paths.

**Rejected:** Documenting "don't write to X" in rules files only.

**Rationale:** Documentation is advisory. An agent operating under pressure (tight context, mid-task, complex debugging) will violate documented rules. Hooks make the violation impossible — the tool call fails before the write happens. The security guarantee is mechanical, not behavioural.

**Tradeoff accepted:** Requires Claude Code's hook system. Not directly portable to other AI coding tools without adaptation.

---

## 5. Task files as the plan, not the chat

**Decided:** Plans go in the task file under `## Approach` before any code is written.

**Rejected:** Planning in chat and immediately coding.

**Rationale:** Chat is ephemeral. The task file survives across sessions, is readable by future agents, and is reviewable alongside the code diff. Requiring the plan to be written into the file before coding starts means there's always a reference point — "what was this supposed to do?" is always answerable. The task file also forces explicit acceptance criteria, out-of-scope declarations, and done notes, which prevent scope creep and clarify when a task is actually complete.

**Tradeoff accepted:** Overhead for tiny changes. Accepted — the discipline pays off on any task that spans more than one exchange.

---

## 6. Issue-before-commit as a hard rule

**Decided:** The GitHub issue must be created before any code is written. The issue number must be in the commit message.

**Rejected:** Creating issues retroactively after the work is done.

**Rationale:** Retroactive issues break the audit trail — the commit message references a number that didn't exist when the commit was made. The reverse order also forces clarity: creating the issue requires articulating what's being built and why before code exists. This catches scope problems early.

**Tradeoff accepted:** Adds a step before every coding session. Worth it — the discipline is exactly the kind of "slow down to go fast" practice that separates maintainable codebases from junkyard codebases.

---

## 7. Commit trailer stripping is aggressive, not selective

**Decided:** Strip all `Co-Authored-By`, `Signed-off-by`, `Made-with`, and "Generated with [tool]" trailers unconditionally.

**Rejected:** Stripping only AI-specific trailers, or making it opt-in.

**Rationale:** The commit history is a portfolio artifact. The goal is clean, human-authored-in-tone commits. Every AI tool injects these trailers by default, and there's no reliable way to distinguish "legitimate" from "injected" at the hook level. The aggressive strip is the right default — if someone genuinely wants to credit a co-author, they can use a custom format that doesn't match the stripped patterns.

**Tradeoff accepted:** Legitimate human co-author credits using standard trailer format would also be stripped. Acceptable for solo or small-team projects. Adjust `filter-commit-message-inplace.sh` if this matters in your context.

---

## 8. Verification requires in-container smoke tests, not just diff review

**Decided:** Any PR touching Docker, dependencies, or the service layer requires an in-container smoke test before committing.

**Rejected:** Trusting diff review to catch all issues.

**Rationale:** Diff review cannot catch: Python import errors (fail at runtime, not at edit time), missing packages (only surface when the container boots), Docker layer issues, or volume mount problems. These failures are invisible until deployment. The in-container requirement was added after real production regressions — it's the single rule that eliminated an entire class of "it works on my machine" bugs.

**Tradeoff accepted:** Slightly slower pre-commit workflow for affected PRs. Worth it — a blocked deployment is more expensive than 60 seconds of verification.

---

## 9. The global CLAUDE.md references the profile via a path variable

**Decided:** `[PROFILE_PATH]` is a placeholder substituted by `install.sh`, not a hardcoded path.

**Rejected:** Hardcoding `~/.your-ai-contexts/PROFILE.md` in the template.

**Rationale:** Different users may want their profile at different paths. The path also contains `~`, which doesn't expand reliably in all contexts. The install script resolves the absolute path at install time and substitutes it, so the installed `CLAUDE.md` always has a concrete path that works.

**Tradeoff accepted:** Requires the install script to run (can't just `cp` the template). Acceptable — `install.sh` is the intended installation method.

---

## 10. The post-tool hook auto-stubs PROGRESS.md rather than requiring manual updates

**Decided:** `post-tool.sh` detects git commits by scanning Bash output for a short hash in brackets, then auto-inserts a dated stub entry.

**Rejected:** Relying solely on the agent to update `PROGRESS.md` during wrap-up.

**Rationale:** Agents under time pressure or approaching a context limit routinely skip housekeeping. The auto-stub means there's always a placeholder entry after every commit — the agent expands it during wrap-up, but if the session ends abruptly, the record still exists. The stub is idempotent (won't duplicate if the hash is already in the file) and clearly marked as auto-logged.

**Tradeoff accepted:** Heuristic-based detection (hash in brackets) could produce false positives if non-commit bash output happens to match the pattern. Accepted — a spurious stub is much less harmful than a missing entry.

---

## 11. `--tracking` flag is orthogonal to `--target`

**Decided:** `--tracking repo|local|external|stealth` is a separate flag that sets the tracking mode independently of `--target` (which only sets the destination path).

**Rejected:** Using `--target` as the signal for tracking mode (i.e. "if `--target` is provided, use local tracking"), which was the original behaviour.

**Rationale:** The original coupling meant that any non-interactive install with `--target` would silently default to local tracking, even when the user intended stealth or external. Decoupling lets users run fully non-interactive stealth installs: `./install.sh --target <path> --tracking stealth --strategy merge`. The interactive prompt still exists when neither flag is provided.

**Tradeoff accepted:** One more flag to remember for scripted installs. Documented in `docs/agent-install.md` with full non-interactive examples.

---

## 12. Global layer now tracked by a separate upgrade manifest

**Decided:** The global layer (`~/.claude/CLAUDE.md`, `~/.claude/skills/`) has its own manifest file (`~/.claude/.rig-global-manifest`) separate from the project-layer `.rig/memory/.rig-manifest`.

**Rejected:** Re-using the project manifest for global files, or having no manifest for the global layer (leaving it unprotected from silent overwrites on upgrade).

**Rationale:** The global and project layers have different file locations and lifecycles. Sharing a manifest would conflate two unrelated sets of files. Without a global manifest, every upgrade run would either silently overwrite `~/.claude/CLAUDE.md` (losing user customizations) or never update it (leaving Rig rule changes undelivered). The separate manifest gives the same upsert/detect-customization behaviour for both layers.

**Tradeoff accepted:** Two manifest files to maintain. Acceptable — they are in different directories and the same `write_manifest_entry()` / `read_manifest_hash()` functions handle both (via temporary `MANIFEST_FILE` redirection).

---

## 13. Issue tracking is configurable per project with per-tracker commit ref enforcement

**Decided:** `issue-tracking: github|linear|trello|gus|none` controls the entire intake and commit workflow. The `commit-msg` hook validates the ref format for the configured tracker at every commit.

**Rejected:** GitHub-only enforcement (the original design), or treating all non-GitHub trackers as `none` (no enforcement).

**Rationale:** Real teams use Linear, Trello, GUS, and other trackers. The original GitHub-only gate would either force teams to set `issue-tracking: none` (losing all enforcement) or use GitHub issues in addition to their real tracker (double bookkeeping). Per-tracker enforcement extends the discipline — commit messages prove the ticket exists for whichever tracker the team uses.

**Tradeoff accepted:** Each new tracker type requires a regex pattern in `commit-msg` and handling in the `/task` intake wizard. Acceptable — the pattern is simple and each tracker has a well-defined ref format.

---

## 14. Python3 JSON parsing for hook input extraction over grep pipelines

**Decided:** Use `python3 -c "import json,sys; print(json.load(sys.stdin).get(...))"` to extract fields from JSON tool input in `pre-tool.sh`.

**Rejected:** `grep -o '"field_name":"[^"]*"' | head -1 | cut -d'"' -f4` — a grep pipeline that was the original implementation for `PATH_ARG` extraction.

**Rationale:** The grep approach silently fails on any path or command string containing an escaped quote character (`\"`). JSON paths like `"/some/path/with\"quote\"/file"` would produce an empty string, causing the path block and governance protection checks to silently skip. The python3 approach correctly handles all valid JSON input including edge cases, and is consistent with how `BASH_CMD` extraction was already implemented in the same file.

**Tradeoff accepted:** Requires python3 to be present on the host (it is on macOS ≥ 10.15 and most Linux distributions). On a system without python3, the extraction returns an empty string via `|| true`, which causes path checks to pass silently — the same failure mode as the grep approach on malformed input. Acceptable: python3 availability is a reasonable baseline for Claude Code environments.

---

## 15. PreCompact/PostCompact hooks for compact checkpoint — implemented in Sprint 4

**Decided:** Use the `PreCompact` and `PostCompact` hook events (shipped in Claude Code) to write and re-inject a compact checkpoint automatically. `pre-compact.sh` writes `.compact-checkpoint-${PPID}.md` before compaction; `post-compact.sh` re-injects it as `additionalContext` after.

**Original decision (superseded):** This entry originally recorded that no pre-compaction hook existed and `/wrap` was the sole compaction safeguard. That was accurate at the time of writing (early 2026). Claude Code subsequently added `PreCompact` and `PostCompact` hook events, making automatic checkpoint handling possible.

**Rejected:** Timestamp-scoped checkpoints (`date +%Y%m%d-%H%M%S`) — less reliable if two compactions land within the same millisecond; leaks files on crash. Canonical shared `.compact-checkpoint.md` — second write clobbers first in concurrent sessions (the original gap this feature was designed to fill).

**Rationale:** `$PPID` (parent PID — the Claude Code process that spawned the hook) is stable across all hook invocations within a session. `pre-compact.sh` and `post-compact.sh` share the same PPID, so they can reliably find each other's files. `session-start.sh` (source=compact) falls back to `ls -t .compact-checkpoint-*.md | head -1` when no PPID-scoped file exists (new session after compaction has a different PPID).

**Consequences:** Compact checkpoints are now PPID-scoped and isolated per session. Concurrent sessions compacting simultaneously no longer clobber each other's checkpoint. `stop.sh` (handling the SessionEnd event) deletes the PPID-scoped checkpoint on close. The `/wrap` proactive-run rule in `CLAUDE.md` is still valid as a belt-and-suspenders safeguard.
