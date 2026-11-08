# Rig gaps triage — 2026-11-07

> **Superseded, 2026-11-07:** The final candidate and impact review is [rig-gaps-impact-review-2026-11-07.md](rig-gaps-impact-review-2026-11-07.md). This preliminary subset found 83 bracket-date entries and later noticed 34 additional dated entries. The final review also includes 14 numbered, undated reports from 4Culture, for 131 local reports in total. Do not file issues from the preliminary groups below; use the final review's current-source validation, classifications and regression gates.

The final review records the approved first-wave issues and draft PRs in a dated follow-through note. This preliminary grouping remains a historical audit trail. Three older `tests/* (1).bats` copies were staged separately in the source checkout. Two omit newer tests; the third has obsolete assertions. None is included with these documents.

Source revision: `05c9e8a` (v1.29.2). This is a validation and planning record, not an implementation or issue filing. Three staged `tests/* (1).bats` files predated this review and were left untouched.

## Collection and evidence

The shipped `$rig-gaps --collect` reference script found **83 entries within its narrow input set** in seven external project logs: the-rig 48, laudtetteh-io-react 16, zap 10, dedoress 6, and one each in 7directions, www, and scrap. Its scope/title matching found no exact duplicates within that subset. This count includes already addressed historical entries because the collector filters `[submitted]`, not `**Status**: addressed`; almost all old entries lack a `**Scope**` field and therefore appear as `needs-review`. The pasted work-machine batch adds 19 reports from five other projects. Snapshot and backup copies were excluded by the collector's canonical path glob.

Sources checked: shipped `templates/project/` (especially `bin/rig`, command and hook templates), `install.sh`, local gap and error logs, tests, available GitHub issue history, and the upstream release audit. No open Rig GitHub issues were returned during the available issue query; closed #529, #530, #533, #537, #561, #575–#585 explain several historical reports. The upstream cursor and review findings are in the machine-local `UPSTREAM_RELEASE_AUDIT.md`.

Evidence terms: **confirmed** means the defect or absent feature is visible in shipped source or reproduced; **partial** means a narrower defect is supported but the proposed mechanism or downstream impact needs a fixture; **stale** means current source already addresses the reported behavior; **external/project** means ownership lies outside the Rig core; **decision** means the requested behavior changes governance and needs an explicit design choice.

## Work-machine batch disposition

| # | Disposition | Validation and canonical destination |
|---|---|---|
| 1 | Partial, high risk | Historical-base convergence exists (#561), so “all customized files are skipped” is outdated. Missing manifest entries, lifecycle-hook stranding and misleading whole-install version claims still need a v1.27 fixture. `rig version` prints only `.rig/VERSION`; doctor compares recorded hashes but does not prove `session bind` is present. Fold into **A**. |
| 2 | Confirmed source defect | `wrap.md` still reads literal `.rig/tasks/active/` in its collection and capture steps; `ship.md` and `post-merge.md` also contain literal task paths. Reproduce with an external `.rigpath`, then fix as **B**. |
| 3 | Confirmed, reproduced | `/bin/bash` 3.2 raises `original[@]: unbound variable` for empty argv. `session_current` also discards failed resolver output with `|| return $?`. Fold into **C**. |
| 4 | Confirmed mechanism | `session_resolve` uses `python3 - <<'PY'`, which requires shell temporary storage; a read-only Codex run itself has not been replayed here. Fold into **C**, with a read-only fixture. |
| 5 | Partial | `SessionStart` binding exists; app-server reattach behavior is untested. `retrofit --from-env` needs `CODEX_THREAD_ID`, which the pasted environment says is unset; the suggested fallback therefore cannot be the only recovery path. Fold into **D**. |
| 6 | Confirmed feature gap | There is no `session reap` command. Existing session doctor/repair do not age out dead records. Design retention and wrap-obligation handling as **D**. |
| 7 | Confirmed polish | Subcommand-specific `--help` is absent; bind output hard-codes `native_session_id: null` and omits continuation lineage, although the record stores it. Fold into **C/D**. |
| 8 | Partial | Linear is already supported by `issue-tracking`; command examples still use `#N`. Validate whether examples caused real local edits before selecting a placeholder or local extension point. Fold into **A**. |
| 9 | Partly stale | Current installer explicitly skips `.husky/*` for stealth installs and routes hooks to `.git/hooks`. A stale manifest entry may still be involved; reproduce the upgrade path before opening a new bug. Fold into **A**. |
| 10 | Confirmed source defect | Both `commit-msg` and `post-commit` resolve the filter only under `.husky/`; native installs copy it into `.git/hooks`. Fallback strips human trailers; filter lacks Codex and emoji/link-prefixed footer patterns. Fix as **E**. |
| 11 | Confirmed source defect | Snapshot writer atomically replaces the *entire* file. The empty lock only serializes writers; it cannot preserve another live workstream's sections. Fix as **F**. |
| 12 | Confirmed | Both workflow commands create an empty lock with `touch`; the only recovery is a 30-minute age rule/manual removal. Add ownership and stale-owner detection under **F**. |
| 13 | Confirmed missing check | `prompt-submit.sh` checks flags/hand-off but never compares the session branch with the checkout branch. Add under **F**, including a cheap fast path. |
| 14 | Valid feature request | A memory checkpoint that keeps a session active is distinct from a final wrap. Design under **G**, with continuation semantics shared with **D**. |
| 15 | Valid feature request | No promotion marker or lesson-promotion step exists in shipped wrap. Make opt-in or narrow and avoid changing both provider copies by hand; **G**. |
| 16 | Valid need, proposed scan too broad | Reusable helpers can be lost, but scanning all of `/private/tmp` by mtime cannot reliably attribute ownership and risks secret files. Capture explicitly named helpers in a session manifest; **G**. |
| 17 | Decision | `rig-propose` explicitly says approved changes to protected files remain blocked. An apply path changes the governance boundary and requires a narrow owner-approved design. Track separately as **J**; do not treat wording as an accidental bug. |
| 18 | Partial | `codex_skill_parity` compares names only. Generated `.codex/hooks.json` **already includes `UserPromptSubmit`**, so that subclaim is stale. Existing `AGENTS.md` is intentionally preserved while Codex config uses `CLAUDE.md` fallback; `@import` behavior and global-root comparison need targeted validation. Scope **H** to demonstrable content drift. |
| 19 | Valid feature request | No atomic `rig skill retire` exists. Assess value and required provider/registry behavior under **H**, after the parity inventory is trustworthy. |

## Local logs: cleaned routing

The 83 collector-visible entries were routed as reports, not assumed to be 83 new defects. The following routing is preliminary and omits the later-discovered logs and malformed date headers; it preserves the subset's provenance without rewriting other projects' logs.

| Source | Reports that remain in Rig-core consideration | Historical, project, or upstream routing |
|---|---|---|
| `the-rig` (48) | Installer tracking/upgrade provenance and stealth migration → **A**; session continuation/naming → **D/G**; direct-push guard and issue conventions → **I**; stale developer command mirror → **H**; memory ordering and release version sync → **I**. | Explicitly addressed: #533 recovery, #537 docs drift, #536 delegated validation, issue-first intake, feature docs, Husky coexistence, `--tracking`, self-install safety, debug pattern, issue tracker support, gap status field, scanner exclusions, session naming, commit subject stubs, settings dedupe, `.rig/VERSION`, global upgrade path, upgrade workflow. Source inspection also shows `$sprint`, `$rig-gaps --push`, `--project-only`, permission reduction guidance, batch support, worktree merge guidance, and stale commit-sentinel expiry. #476 remains a closed issue; re-open only with a fresh reproduction. The subagent harness filter report belongs to the host, not Rig core. |
| `laudtetteh-io-react` (16) | ERRORS marker/count ordering → **I**; continued-session and orphan records → **D/G**; concurrent snapshot overwrite → **F**; provider upgrade and stealth external docs → **A/H** (re-check current implementation); durable reasoning checkpoint → **G**. | Native `/rename` success and timestamp corruption need a contemporary reproduction and provider ownership check. `rig-propose` now exists; gitleaks config/finding distinction closed in #582; pre-compaction naming evidence was improved in #577 but the Sept observations warrant a regression fixture. Local `.github` excludes and personal global skill registration are project/machine configuration. |
| `zap` (10) | Session-name content at 16+ units → **G**; optional component upgrade convergence → **A**; ERRORS/PROGRESS ordering → **I**; migration collision guidance → **I** if still current. | Multi-PR ceremony addressed in #580; `.rig-commit-ok` expiry addressed in #583. Agent live tracking is host/runtime; `[#N]` issue autoclose is a project commit/PR convention, not a Rig bug without a shared rule. |
| `dedoress` (6) | Cross-session work visibility → **F**; task/issue/PR cardinality → **I** only if #580 did not cover it; PROGRESS `sid:` format → **I**. | `/rename` is native/provider behavior pending reproduction; browser extension and reference CSS tools are external/project workflows. |
| `7directions` (1) | Pre-compaction work omitted by wrap → **G**; compare #577 against this later Sept observation. | — |
| `www` (1) | Scaffold refusal handling: closed by #585; check its generator-specific acceptance if it recurs. | — |
| `scrap` (1) | — | Background subagent `AskUserQuestion` availability is host capability; route to host guidance, not Rig runtime. |

## Canonical implementation candidates

Order reflects data-loss and upgrade risk first. A letter is a triage grouping, not a pre-approved issue count; split it into small tasks after fixtures show the exact failing surfaces. Every ticket should include a pre-fix reproduction and a post-fix acceptance check.

| Group | Priority | Scope and acceptance gate |
|---|---|---|
| **A. Upgrade integrity** | P1 | v1.27 customized lifecycle hook and missing/contradictory manifest fixture; prove resulting hook binds, explain every refusal, distinguish installed layer/version from file convergence, validate stealth manifest targets and optional components. Do not blindly replace local hooks. |
| **B. External task paths** | P1 | Stealth `.rigpath` fixture with six external active tasks; wrap preserves all six `Resuming from` blocks, ship/post-merge resolve the same directory, missing task dir is an error. A `rig task list --json` helper is optional if direct path correction suffices. |
| **C. Portable, read-only session queries** | P1 | Bash 3.2 empty argv; failed resolver emits JSON reason and a human reason; `resolve/current` work in a read-only sandbox. Audit other empty array expansions. |
| **D. Session continuity and retention** | P1 | Test fresh/resumed TUI and app-server attach separately; offer a recovery path that works without an env ID. Continuation output includes lineage; retention dry-run names dead PID, age, and unresolved obligations; apply is reversible. |
| **E. Commit attribution filter** | P1 | Native hook fixture removes AI attribution including Codex/emoji/link forms; human `Co-authored-by` and `Signed-off-by` remain; verify no unintended amend. |
| **F. Concurrent workstreams** | P1 | Two active tasks each wrap and both handoffs survive; lock contains owner/age and recovers from a dead owner; branch-switch warning names previous/current branches. |
| **G. Checkpoint and memory quality** | P2 | Keep-session checkpoint records work without closing the session; wrap carries pre-compaction evidence; optional lesson promotion records source/target; helper retention requires explicit file selection. |
| **H. Provider parity and retirement** | P2 | Compare content, scripts, brain references, and hook events with provider-only exceptions; report exact drift. `fix` backs up and requires explicit scope. Skill retirement follows only after canonical provider inventory is defined. |
| **I. Local workflow hygiene** | P2/P3 | Validate ERRORS/PROGRESS order and counts, branch/issue conventions, migration collision guidance, and version sync against current templates. File only independently reproducible residuals. |
| **J. Governance apply decision** | Decision | Define whether owner-approved protected-path apply is permitted; if approved, bind approval to an exact diff and path set, then read back and validate. |

## Next implementation sequence

1. Create focused fixtures for **C**, **B**, **E**, and **F**; these have direct source evidence and limited design ambiguity.
2. Reproduce **A** with an old customized install before deciding any manifest migration or must-converge policy.
3. Validate app-server resume and retention obligations for **D**; choose safe lifecycle semantics before **G**.
4. Audit provider roots and generator behavior for **H**; file only remaining drift. Review **I/J** after the safety work.

No implementation issue should inherit the pasted priority or proposed fix without a current reproduction. Keep source entries as historical evidence; record resolved/duplicate links in the eventual issue or task rather than deleting observations.

## Entry-level local index

Each semicolon-separated phrase below names one collector-visible entry in its source project's `memory/RIG_GAPS.md`. `A`–`J` point to the preliminary groups above; `closed` cites an existing fix or current surface, but is not a completed current-version verification; `verify` needs a fresh fixture; `project/host` suggests ownership outside Rig core. This index omits entries missed by the collector.

### the-rig (48)

1. post-merge + wrap `not_found` recovery — closed #533; public docs drift check — closed #537; delegated full-suite drift — closed #536; issue #476 CI reachability — verify #476; duplicate sprint validation — verify I; dogfood wrap mirror drift — H; concurrent naming boundaries — D/G; direct-push code guard — verify I.
2. two VERSION files — verify I; stealth upgrade without tracking flag — verify A; `git add -f` in stealth templates — project/host; empty-stdin tracking default — verify A; upgrade PR/direct-push convention — verify I; missing branch creation in task workflow — closed #176; feature-doc lookup/freshness — closed #166/#167; missing sprint command — closed (shipped `$sprint`).
3. feature docs in stealth — verify I; Husky coexistence — closed v1.11.0; missing `--tracking` — closed #142; self-install deletion — closed; debug-pattern false positive — closed; stealth migration residue — verify A; gap developer push — closed (shipped `--push`); tracker/issue-creator support — closed #155.
4. maintenance commit issue gate — verify I; inability to identify addressed gaps — closed (status field exists; collector still ignores it, which is a narrower I defect); vendor debug scan — closed; session naming convention — closed; debug-artifact guard — verify I; progress stub subject — closed; snapshot not written at end — verify F/G; batch issue/PR scaffold — verify I.
5. task issue-first intake — closed v1.13.0; pre-commit `git add`/index.lock — verify I; settings merge duplicates — closed; `.rig/VERSION` not updated — closed; installer branch drift — verify A; global brain upgrade path — closed #152; absent upgrade workflow — closed; `--project-only` menu — verify A.
6. stale-version warning — verify A; multi-input piping — verify A; permission-prompt reduction — closed (skill exists); multi-PR review — verify I; backgrounded bats tracking — verify I; worktree merge/delete-branch — closed #535; continued session after wrap — D/G; instruction-shaped subagent output filter — project/host.

### laudtetteh-io-react (16)

1. ERRORS trim stub ordering — I; ERRORS count includes format headers — I; wrap closes continuing thread — D/G; rename then wrap unresolved and unrelated snapshot overwrite — D/F, with native rename behavior to verify; pre-compaction naming undercount — verify G after #577; Codex infrastructure absent after old upgrade — verify A/H after #530.
2. bare relative external-doc paths — verify A after #584; stealth `.github` excludes/worktree files — project/host, with Rig worktree bootstrap to check; rename corrupts snapshot timestamp — verify native/provider ownership; snapshot drift from repo — F/G; orphan active records — D; task references missing rig-propose — closed (skill exists).
3. personal global skill not registered — project/host; gitleaks config mislabeled — closed #582; shared snapshot overwrite — F; reasoning lost before compaction — G.

### zap (10)

1. generic 16+ unit session name — G; optional upgrade components silently skipped — verify A; lost background agent tracking — project/host; `[#N]` does not close issues — project convention; ERRORS ordering contradiction — I.
2. multi-PR post-merge ceremony — closed #580, verify if residual; stale commit sentinel — closed #583; migration destination already occupied — verify I; missing ERRORS trim marker — I; mid-session PROGRESS order — I.

### dedoress (6)

1. duplicate logo build across sessions — F; native rename stdout/file mismatch — verify provider behavior; Chrome extension unavailable — project/host; computed reference CSS extraction — project/host; task assumes 1:1 issue/PR — verify I after #580; PROGRESS `sid` format omitted — I.

### Remaining (3)

- 7directions: pre-compaction wrap naming omission — verify G after #577.
- www: scaffold generator refusal — closed #585; verify generator-specific recurrence.
- scrap: background subagent question tool unavailable — project/host.
