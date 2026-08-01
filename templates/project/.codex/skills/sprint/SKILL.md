---
name: sprint
description: Audit, plan, resume, and coordinate a durable Rig sprint.
---

# Sprint

Read `.rig/processes/SPRINT_WORKFLOW.md` completely and follow it as the canonical
contract. This skill is a thin Codex adapter: collect user intent and documented
public tracker evidence, invoke `rig sprint audit|plan|status --json`, render the
result, and obtain required approvals. Use the exact #409 root session context;
never add a sprint resolver or inspect private provider databases, indexes,
rollout/transcript formats, or prompts. Approved tasks execute through their
existing task and ship gates, including #376 validation evidence.
