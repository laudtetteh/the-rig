# Workflow preference inventory (2026-11-18)

**Status:** Verified research for #685. Proposed issue creations await the owner's approval of each exact action.
**Source:** The Rig `main` at `eb27510` (PR #682 merged). Two independent source audits, one adversarial verifier, and coordinator checks. Relevant claims were checked again against this tree before recording them here. No issue, label, or comment was created by this audit.

## Verified inventory

| Preference or behavior | Classification | Evidence and observed impact | Disposition |
|---|---|---|---|
| `issue-tracking:` accepts a closed list, with tracker-specific reference patterns in hooks and commands | Hardcoded preference | `templates/project/.husky/commit-msg:8`; `templates/project/bin/rig:2129`; an unknown tracker cannot use the shipped workflow generically | #683 owns the shared parser and generic fallback |
| `type:` and `area:` labels are assumed during PR metadata review and shipping | Configurable only by editing Rig-owned workflow files | `templates/project/bin/rig:637-646`; `ship.md` and `SHIP_WORKFLOW.md` add those labels | #674's approved `pr-labels: on|off` design; missing labels should warn and skip |
| Conventional Commit types, branch prefixes, and a 72-character subject limit are fixed | Hardcoded preference | `templates/project/.husky/commit-msg:138-148`, `.rig/rules/git-conventions.md:5-30`, `templates/global/CLAUDE.md:205-216`. A throwaway hook invocation rejected `build: sample` | Proposed issue A below; #665 covers parser consistency but not configurability |
| `commit-cleanup: no` is advertised but has no effect | Broken setting | `templates/project/CLAUDE.md:156-163`; `.husky/commit-msg:98-109`; `.husky/post-commit:81-116`. A throwaway repo with the setting still stripped a Co-authored-by footer | Proposed issue B; preserve other commit guards when cleanup is disabled |
| Scaffold `housekeeping: direct-push` and the upgrade's three-file direct-commit threshold | Configurable but opinionated default | `templates/project/CLAUDE.md:103-116`; `POST_MERGE_WORKFLOW.md:206-250`; `UPGRADE_WORKFLOW.md:264-265`. The shipped default permits a later base-branch push | Proposed issue C; explicit owner choice of the new default and migration |
| `--target` noninteractive installs select all components, including GitHub templates | Missing extension point | `install.sh:4075-4124,4166`. A throwaway `issue-tracking: linear` project still received `.github/ISSUE_TEMPLATE/*` and `PULL_REQUEST_TEMPLATE.md` | Fold into #674's approved `pr-host: none` implementation or a separate component selector |
| `/wrap` archives PROGRESS after 20 entries and ERRORS after 30 | Hardcoded retention policy | `templates/project/.claude/commands/wrap.md:337-352,489-510`; archives are gitignored by `.rig/memory/.gitignore:15-21`. Transcript retention is separately opt-in and configurable | Proposed issue D; owner chooses defaults and upgrade behavior |
| Global instructions require `/task` intake and a confirmation before tools for multi-file work | Hardcoded workflow preference | `templates/global/CLAUDE.md:77-93,188-200`; no project setting controls the gate | Proposed issue E; move optional policy to project configuration |
| PermissionRequest hook auto-approves read inspection and Rig Markdown notes by default | Configurable but opinionated default | `templates/project/.claude/hooks/permission-request.sh:4-20,159-182`; `.rig-strict-permissions` is an opt-out. #675 hardened the scope but did not decide the default | Proposed issue F; owner decides opt-in or explicit install choice |
| `secret-scanner: none` is unread by the pre-commit hook | Broken setting | `templates/project/CLAUDE.md:147-153`; `.husky/pre-commit:22-80` still runs gitleaks when installed | #665 owns setting-consistency repair |
| Tracker writes can occur after general workflow approval | External write without item-specific approval | `NEW_TASK_WORKFLOW.md`, `ship.md`, `SHIP_WORKFLOW.md`, `rig-gaps.md`; #680 draft also inherits the gap | #684 owns the action-specific approval gate; #656 depends on it |
| `~/code`, `~/.rig`, `~/tools/the-rig`, `origin`, and provider config locations | Mixed: documented defaults and hardcoded uses | `--rig-dir` and `RIG_INSTALLER_SRC` already allow two location overrides; project-root gaps are in #668; remote and provider config gaps are in #674 | Fold into #668/#674. Do not file duplicate path issues |

## Proposed implementation issues

**A — feat(config): make commit and branch conventions configurable.** Add project settings for accepted commit types, branch prefixes, and subject limit; make hook, shipped rules, command guidance, and Codex mirrors use one policy. Existing installs retain their current policy until they opt into a new one or accept a documented migration. Tests cover a custom `build:` type and a nonstandard branch prefix.

**B — fix(hooks): honor `commit-cleanup: no` without disabling commit guards.** Both commit-msg and post-commit footer filters read the setting. With `no`, a footer is preserved while branch, issue-reference, and commit-approval checks still run. Test both `yes` and `no` during install and upgrade.

**C — chore(config): choose a neutral housekeeping default.** Decide whether fresh installs default to `branch-pr`, `ask`, or another explicit mode; make the upgrade's small-change direct-commit rule follow the same setting. Document how existing user-owned `CLAUDE.md` values are preserved. No base-branch push occurs merely because the scaffold chose it.

**D — feat(wrap): configure PROGRESS and ERRORS retention.** Add explicit settings for the two entry limits and a no-auto-trim mode; make wrap and docs honor them. Preserve archives and report where they live. Existing projects retain the old limits until the owner selects migration behavior.

**E — feat(policy): make global task-intake rules optional per project.** Replace unconditional global multi-file `/task` and pre-tool confirmation rules with an explicit project policy, and keep the no-policy path usable for a downstream user's workflow. Validate generated Claude/Codex guidance and upgrade notes.

**F — chore(permissions): decide the default for Rig Markdown auto-approval.** Offer an install/config choice or opt-in default for PermissionRequest auto-approvals, retaining the narrow protections shipped in #675. Test both modes and upgrade behavior.

## Filing status and decisions

- None of A–F has been filed. The owner must approve each specific issue creation above, or direct a fold into an existing issue. This report authorizes none of them.
- #674 can own the scripted GitHub-template exclusion as part of `pr-host: none`; if it does not, it needs its own issue.
- #685 remains open until approved issues are filed or explicitly folded and this inventory is linked from its tracker item.
