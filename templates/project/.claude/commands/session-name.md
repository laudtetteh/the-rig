# Command: /session-name

Derive a session name from work completed so far and present it as a ready-to-run
suggestion. Can be run at any point in the session — not just at wrap time.

---

## What this does

1. Reads `$RIG_DIR/rules/session-naming.md` and applies it as the canonical
   session-local evidence contract
2. Resolves this session with `bin/rig session resolve --json` (launcher identity
   first, then the legacy PPID sentinel); unresolved raw launches use conversation
   context only
3. Reads any existing `tentative_name` from the resolved current session file
4. Derives a name in the standard `type short-desc #N | ...` format using conversation
   context as the primary signal and UUID-tagged PROGRESS entries as cross-reference
5. Presents it as output — does **not** run anything automatically
6. After you confirm, writes the name to the session file (`tentative_name` if called
   early, `final_name` if called at session end). Never writes to CONTEXT_SNAPSHOT.md.

This is the same logic used by `/wrap` and `/post-merge`, but callable at any time
without triggering a full wrap or post-merge cycle.

---

## Usage

```
/session-name
```

No arguments. Run it whenever you want to name or re-name the current session.

> **RIG_DIR resolution (stealth mode):** Before reading any `.rig/` path, resolve where
> `.rig/` actually lives. If `.rigpath` exists at the project root, read it — it contains
> the absolute path to the external `.rig/` directory. Substitute `$RIG_DIR` for `.rig/`
> in every step below.

---

## Steps

### 0 — Load the canonical contract and find this session's file

Read `$RIG_DIR/rules/session-naming.md` completely before collecting naming
evidence. It is authoritative for evidence eligibility and contamination checks.

```bash
REPO=$(git rev-parse --show-toplevel 2>/dev/null)
SESSION_JSON=$("$REPO/bin/rig" session resolve --json 2>/dev/null || true)
SESSION_FILE=$(printf '%s' "$SESSION_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("session_file") or "")' 2>/dev/null || true)
SESSION_UUID=$(printf '%s' "$SESSION_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("anchor") or "")' 2>/dev/null || true)
TENTATIVE_NAME=""
if [[ -n "$SESSION_FILE" ]]; then
  TENTATIVE_NAME=$(SESSION_F="$SESSION_FILE" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); print(d.get("names",{}).get("tentative") or d.get("tentative_name") or "")')
fi
```

### 1 — Determine what happened this session

**Your conversation context is the primary signal** — what was done, PRs opened or
merged, tasks completed. If called early in the session to set a tentative name, use
the stated intent as the basis.

File signals from the resolved current session are cross-reference only:
- **`naming_evidence.progress_titles` in the exact active session file** — same-session progress titles recorded by Rig writers before compaction
- **UUID-tagged PROGRESS entries** — `grep "^## .*<!-- sid:${SESSION_UUID} -->"` to find entries from this session
- **`tentative_name` in session file** — set pre-compaction; use as the base if context was lost to compaction
- **Compact checkpoint Session naming evidence** — only from `.compact-checkpoint-${SESSION_UUID}.md`, and only if its `Session anchor` matches `SESSION_UUID`

**If conversation context and file signals conflict, trust the conversation.**
Never use `CONTEXT_SNAPSHOT.md`, checkpoints for another anchor, legacy markers,
unrelated session files, other-session UUID entries, or general project history
as naming evidence. If resolution failed, use conversation context only. An
unresolved raw launch must never inherit unrelated prior-session work.

### 2 — Check for an existing tentative name

Read `tentative_name` from the session file (step 0 above).

- **If blank / absent:** derive a fresh name from this session's work.
- **If set as tentative** (`[tentative]` suffix): suggest upgrading it to a final
  name if the session delivered what it described, or updating it if scope changed.
- **If this command is called early** (before much work has happened): set a tentative
  name explicitly — append `[tentative]` to mark it as subject to refinement at `/wrap`.

### 3 — Derive the name

Use a **tiered format** based on how many meaningful units of work this session produced.
Count one "unit" per merged PR, completed task, or significant fix.

#### Tier 1 — ≤5 units (list format)

```
type short-desc #N | type short-desc #N | ...
```

- `type` matches a git commit type: `fix`, `feat`, `chore`, `refactor`, `devops`, `docs`, `test`
- `short-desc` is 3–6 words — enough to identify the work at a glance
- Include the PR or issue number when known
- Keep under ~100 characters

Example: `fix step accordion layout #184 | feat custom-permissions #152`

#### Tier 2 — 6–15 units (grouped format)

Group by commit type. For each type, list the 1–3 most significant feature areas
affected (omit the rest). Include a count if there were more.

```
type(area, area) | type(area) x3 | type x2
```

Example: `feat(auth, dashboard) | fix(billing x4, ui) | chore x3`

- Use the scope area, not individual issue numbers
- `x N` suffix means N items of that type; omit if N = 1
- Keep under ~100 characters; drop the smallest groups if over

#### Tier 3 — 16+ units (sprint summary format)

```
sprint: N issues · feat/X fix/Y chore/Z · #A–#B
```

- `N` is the total issue/PR count
- `feat/X fix/Y chore/Z` shows the count per dominant type (omit types with 0)
- `#A–#B` is the issue number range (lowest to highest)
- Keep to one line

Example: `sprint: 23 issues · feat/4 fix/15 chore/4 · #130–#152`

If the session covered a named milestone or sprint, use the milestone name as a
prefix: `milestone: Sprint 3 · 23 issues · feat/4 fix/15 · #130–#152`

### 4 — Present the suggestion

Output the name as plain text:

> **Suggested session name:**
> `feat user-auth magic-link flow #91`

Then invite the user to apply it:

> To apply: say "use that name" or "lgtm".

Do **not** run anything automatically. Present it for the user to confirm, copy, or tweak.

### 5 — After confirmation

When the user confirms the name:

**5a — Determine if this is a tentative or final name.**

- Called early in session (before most work is done) → write as `tentative_name`
  with `[tentative]` suffix.
- Called mid-session or at wrap time → write as `final_name`; clear `tentative_name`.

**5b — Write to session file.**

Pass the confirmed name as one opaque argument to the atomic writer. Never interpolate
it into shell or Python source:

```bash
"$REPO/bin/rig" session-name set --tentative "$CONFIRMED_NAME" # early
"$REPO/bin/rig" session-name set --final "$CONFIRMED_NAME"     # mid-session/final
```

**Do NOT write Session name to CONTEXT_SNAPSHOT.md.** CONTEXT_SNAPSHOT is
project state only. Session names belong in session files.

**5c — Log the name in PROGRESS.md if writing final.**

If writing a final name, add a note at the top of PROGRESS.md:
```
## [date] — Session named: [final name] <!-- sid:[UUID] -->
```

---

## Notes

- If called early with no work done yet, still write a tentative name if the user
  states intent — that anchor is more valuable than nothing.
- If the session file does not exist or cannot be resolved, derive only from the
  current conversation. Do not recover a name from project history.
- **Setting tentative names early** is encouraged — the tentative name survives
  compaction and gives post-compaction agents a reliable anchor without needing to
  reconstruct work from file signals alone.
- **Why not `/rename`?** Claude Code has a built-in `/rename` command that renames
  the conversation. This command was renamed to `/session-name` to avoid the conflict.
