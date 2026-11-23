---
name: sprint
description: Audit, plan, resume, and coordinate a durable Rig sprint.
---

# Sprint

Read `.rig/processes/SPRINT_WORKFLOW.md` completely and follow it as the canonical
contract. This skill is a thin Codex adapter. Collect task slugs, issue refs,
or `--all`; choose `audit-only`, `plan-only`, `repair-and-plan`, or `resume`,
with an explicit sprint ID for resume. Collect documented public tracker
evidence, resolve `REPO=$(git rev-parse --show-toplevel)` and stop if it fails,
then invoke `"$REPO/bin/rig" sprint audit|plan|status --json`, render the result, and
obtain the approvals required by the canonical process. Use the exact #409
root session context; never add a sprint resolver or inspect private provider
databases, indexes, rollout/transcript formats, or prompts.

For work spanning multiple issues or PRs, record the N-issues-to-M-PRs batch
ledger. Before launch, write a Dependency Surface Audit for each ticket or
lane, including generated artifacts, install/upgrade paths, cross-agent
parity, and persistent state. Re-plan and obtain fresh approval if it changes
order, ownership, or shared-file exclusivity. Approved tasks execute through
their existing task and ship gates, including #376 live validation evidence.
Check closing keywords for every issue completed by a multi-issue PR; leave a
split issue open until its final PR. Tell review and validation workers
explicitly never to run the full local `bats tests/` suite without a
coordinator exception.
