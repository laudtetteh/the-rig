# Workflow preference inventory (2026-11-18)

**Status (2026-11-20):** Verified inventory for #685. Follow-on issues A–F were filed as #697–#702 after owner authorization and review of the exact drafts.
**Source:** The Rig `main` at `eb27510` (PR #682 merged). Two independent source audits, one adversarial verifier, and coordinator checks. Relevant claims were checked again against this tree before recording them here. The inventory describes that baseline; #683/#684/#656 were implemented in later merged PRs #696/#692/#680. The follow-on issues were created on 2026-11-20, after the research pass.

## Verified inventory

| Preference or behavior | Classification | Evidence and observed impact | Disposition |
|---|---|---|---|
| `issue-tracking:` accepts a closed list, with tracker-specific reference patterns in hooks and commands | Hardcoded preference | `templates/project/.husky/commit-msg:8`; `templates/project/bin/rig:2129`; an unknown tracker cannot use the shipped workflow generically | #683 owns the shared parser and generic fallback |
| `type:` and `area:` labels are assumed during PR metadata review and shipping | Configurable only by editing Rig-owned workflow files | `templates/project/bin/rig:637-646`; `templates/project/.claude/commands/ship.md:659-664`; `templates/project/.rig/processes/SHIP_WORKFLOW.md:386-387` add those labels | #674's approved `pr-labels: on|off` design; missing labels should warn and skip |
| Conventional Commit types, branch prefixes, and a 72-character subject limit are fixed | Hardcoded preference | `templates/project/.husky/commit-msg:138-148`, `.rig/rules/git-conventions.md:5-30`, `templates/global/CLAUDE.md:205-216`. A throwaway hook invocation rejected `build: sample` | #697 below; #665 covers parser consistency but not configurability |
| `commit-cleanup: no` is advertised but has no effect | Broken setting | `templates/project/CLAUDE.md:156-163`; `.husky/commit-msg:98-109`; `.husky/post-commit:81-116`. A throwaway repo with the setting still had its footer stripped by commit-msg; post-commit normally warns and only auto-amends with `RIG_POST_COMMIT_AUTO_AMEND=1` | #698; preserve other commit guards when cleanup is disabled |
| Scaffold `housekeeping: direct-push` and the upgrade's three-file direct-commit threshold | Configurable but opinionated default; contradictory docs | `templates/project/CLAUDE.md:103-116` says the setting excludes upgrades, while `templates/project/.rig/processes/UPGRADE_WORKFLOW.md:277-280` and `templates/project/.claude/commands/rig-upgrade.md:1621-1624` permit a one-to-three-file direct upgrade commit when the setting is `direct-push`; `templates/project/.rig/processes/POST_MERGE_WORKFLOW.md:206-250` uses it for housekeeping | #699; choose the new default, preserve the existing upgrade condition unless explicitly changed, and reconcile the docs |
| `--target` noninteractive installs select all components, including GitHub templates | Missing extension point | `install.sh:4188-4201,4213,4280` selects all components and `.github/*`. A throwaway `issue-tracking: linear` project still received `.github/ISSUE_TEMPLATE/*` and `PULL_REQUEST_TEMPLATE.md` | Fold into #674's approved `pr-host: none` implementation or a separate component selector |
| Stealth tracking is the installer fallback | Configurable but opinionated default | `install.sh:4057-4065,4067-4077` chooses stealth without an explicit tracking flag or as the interactive default; `install.sh:786` incorrectly calls `repo` the default in help | Retain the safety default and correct the help text under the adjacent documentation finding on local `TASK_671_install_scope_skill_format.md` (GitHub issue #671 still needs that scope reflected); `--tracking` lets the owner choose another mode |
| `issue-creator: user` is the project default | Configurable with neutral default | `templates/project/CLAUDE.md:137-144` requires the user to supply an issue number unless they select `agent` | Retain `user`; #684 narrows `agent` to draft-then-approve |
| `/wrap` archives PROGRESS after 20 entries and ERRORS after 30 | Hardcoded retention policy | `templates/project/.claude/commands/wrap.md:337-352,489-510`; archives are gitignored by `.rig/memory/.gitignore:15-21`. Transcript retention is separately opt-in and configurable | #700; owner chooses defaults and upgrade behavior |
| Global instructions require `/task` intake and a confirmation before tools for multi-file work | Hardcoded workflow preference | `templates/global/CLAUDE.md:77-93,188-200`; no project setting controls the gate | #701; move optional policy to project configuration |
| PermissionRequest hook auto-approves read inspection and Rig Markdown notes by default | Configurable but opinionated default | `templates/project/.claude/hooks/permission-request.sh:4-20,159-182`; `.rig-strict-permissions` is an opt-out. #675 hardened the scope but did not decide the default | #702; owner decides opt-in or explicit install choice |
| `secret-scanner: none` is unread by the pre-commit hook | Broken setting | `templates/project/CLAUDE.md:147-153`; `.husky/pre-commit:22-80` still runs gitleaks when installed | #665 owns setting-consistency repair |
| Tracker writes can occur after general workflow approval | External write without item-specific approval | `templates/project/.rig/processes/NEW_TASK_WORKFLOW.md:28-33` creates an issue under the `agent` setting; `templates/project/.rig/processes/SHIP_WORKFLOW.md:28-35,59-74` creates issues and labels; `templates/project/.claude/commands/ship.md:653-665` applies PR labels. `/rig-gaps --submit` already has per-entry yes/edit/skip at `templates/project/.claude/commands/rig-gaps.md:480-520`, but its preview needs exact target/title/body/label and revised-body approval | #684 owns the exact-action approval gate; #656 depends on it |
| `~/code`, `~/.rig`, `~/tools/the-rig`, `origin`, and provider config locations | Mixed: documented defaults and hardcoded uses | `templates/project/bin/rig-session-index.py:122,138` and `templates/project/.claude/commands/rig-gaps.md:124-126` scan fixed roots; `install.sh:4033-4055` defaults to `~/.rig`; `templates/project/.rig/processes/UPGRADE_WORKFLOW.md:15,38-40` describes installer source and remote; `install.sh:186,3629` and `templates/project/.codex/hooks/rig-adapter.sh:209-210` fix Claude config paths. `--rig-dir` and `RIG_INSTALLER_SRC` already override two locations | Fold into #668/#674. Do not file duplicate path issues |

## Reviewed configurable defaults

| Choice | Evidence | Disposition |
|---|---|---|
| Base branch resolves from the target config, then remote HEAD, then `main` | `templates/project/CLAUDE.md:92`; `install.sh:3932-3952` | Configurable with a conventional fallback; #659 fixed the parser, so no new issue |
| GitHub is the issue-tracking default; `user` is the issue-creator default | `templates/project/CLAUDE.md:126-144`; `templates/global/CLAUDE.md:88` | #683 owns tracker extension; retain the neutral `user` creator default |
| Secret scanning defaults to gitleaks, with a documented `none` value | `templates/project/CLAUDE.md:147-153`; `templates/project/.husky/pre-commit:22-80` | #665 owns the broken `none` behavior; no second ticket |
| Feature docs, subagents, contributor commands, notifications and Git-hook bypass are opt-in flags | `install.sh:700-715,802-827` | Configurable, neutral off defaults; retain |
| Installer strategy and Claude/Codex agent targets are explicit flags | `install.sh:751-776` | Operational and product-scope choices rather than hidden workflow preferences; retain the current supported values |
| Direct Rig-gap push target is unset by default | `templates/project/CLAUDE.md:171-174` | Opt-in; retain |

## Filed implementation issues

**A — #697, feat(config): make commit and branch conventions configurable.** Add project settings for accepted commit types, branch prefixes, and subject limit; make hook, shipped rules, command guidance, and Codex mirrors use one policy. Existing installs retain their current policy until they opt into a new one or accept a documented migration. Tests cover a custom `build:` type and a nonstandard branch prefix.

**B — #698, fix(hooks): honor `commit-cleanup: no` without disabling commit guards.** Both commit-msg and post-commit footer filters read the setting. With `no`, a footer is preserved while branch, issue-reference, and commit-approval checks still run. Test both `yes` and `no` during install and upgrade.

**C — #699, chore(config): choose a neutral housekeeping default.** Decide whether fresh installs default to `pr-required`, `ask`, or another explicit mode; preserve and test the existing condition that permits a one-to-three-file direct upgrade commit only with `housekeeping: direct-push`, unless the owner explicitly changes that behavior. Reconcile the contradictory shipped `CLAUDE.md` upgrade note and document how existing user-owned values are preserved. No base-branch push occurs merely because the scaffold chose it.

**D — #700, feat(wrap): configure PROGRESS and ERRORS retention.** Add explicit settings for the two entry limits and a no-auto-trim mode; make wrap and docs honor them. Preserve archives and report where they live. Existing projects retain the old limits until the owner selects migration behavior.

**E — #701, feat(policy): make global task-intake rules optional per project.** Replace unconditional global multi-file `/task` and pre-tool confirmation rules with an explicit project policy, and keep the no-policy path usable for a downstream user's workflow. Validate generated Claude/Codex guidance and upgrade notes.

**F — #702, chore(permissions): decide the default for Rig Markdown auto-approval.** Offer an install/config choice or opt-in default for PermissionRequest auto-approvals, retaining the narrow protections shipped in #675. Test both modes and upgrade behavior.

## Filing status and decisions

- A–F were filed as #697–#702 after the owner authorized the reviewed drafts. The exact issue bodies and labels are recorded in `$RIG_DIR/docs/proposed-implementation-issues-2026-11-18.md`.
- #704 owns the scripted GitHub-template exclusion as part of `pr-host: none`.
- #685's implementation-ticket requirement is met. This report is linked from draft PR #693, which references #685; merge and issue closeout remain pending.
