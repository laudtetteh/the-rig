# Provider-Neutral Project Brain Spike

Date: 2026-08-14

## Problem

The Rig can run in Claude-only, Codex-only, or combined agent targets. A
Codex-only install does not require the Claude binary, but the canonical project
brain is still named `CLAUDE.md`. Codex loads that file through
`project_doc_fallback_filenames` unless `AGENTS.override.md` or `AGENTS.md`
takes precedence.

That is technically functional, but it is not a fully Claude-free product
model. A user who only uses Codex still sees and edits a Claude-named source of
truth for provider-neutral project conventions.

## Current Model

- `templates/project/CLAUDE.md` is the canonical project brain.
- Claude Code reads `CLAUDE.md` natively.
- Codex reads `CLAUDE.md` through `.codex/config.toml` fallback.
- `bin/rig doctor` treats Codex instructions as healthy when either
  `AGENTS.override.md` / `AGENTS.md` exists or `CLAUDE.md` fallback is present.
- Runtime helpers still parse provider-neutral settings such as
  `issue-tracking` from `CLAUDE.md`.
- Codex command parity is delivered through generated `.agents/skills`.

## Provider Load Order Findings

Verified against official Claude Code and OpenAI Codex documentation on
2026-08-27.

### Claude Code

- Managed policy memory loads broadest, then user instructions such as
  `~/.claude/CLAUDE.md`, then project instructions such as `./CLAUDE.md` or
  `./.claude/CLAUDE.md`, then local project-specific instructions.
- Claude concatenates discovered `CLAUDE.md` files from broader directories to
  more specific directories; closer files appear later in context and therefore
  can override earlier guidance by instruction priority, though they are still
  context rather than enforced configuration.
- User-level rules in `~/.claude/rules/` apply across projects and load before
  project rules.
- Personal skills live under `~/.claude/skills/<skill>/`; project skills live
  under `.claude/skills/<skill>/`. Skills load on demand or when invoked. A
  shared machine-wide Rig workflow belongs in the personal/global skill layer
  only when it is genuinely cross-project and safe outside any one repository.

### Codex

- User-level configuration lives in `~/.codex/config.toml`; trusted projects may
  also have `.codex/config.toml`, but project config cannot override
  machine-local provider, auth, profile, notification, telemetry, or model
  provider keys.
- Codex instruction discovery starts with `~/.codex/AGENTS.override.md` if it
  exists, otherwise `~/.codex/AGENTS.md`. It then walks from the project root to
  the current working directory and includes at most one instruction file per
  directory, preferring `AGENTS.override.md`, then `AGENTS.md`, then configured
  fallback filenames such as `CLAUDE.md`.
- Codex concatenates instruction files from broad to specific. Project and
  nested instructions appear later than global instructions, so they are the
  right place for project-specific constraints and overrides.
- Codex skills are loaded from the configured user/plugin/project skill
  mechanisms exposed by the Codex runtime. Treat machine-wide skills as
  cross-project workflow packaging; keep project-specific skills in the project
  layer so they do not fire in unrelated repositories.

## Interim Placement Guidance

- Machine-wide provider brain entries should hold personal or organization-wide
  defaults only: working style, broadly applicable safety rules, and workflows
  that are correct in any repository.
- Project-level instructions should hold project identity, stack, local commands,
  repository-specific protected paths, issue-tracking conventions, and overrides
  to broader defaults.
- Rig should not move global skills/commands into project templates merely
  because they are useful. Ship them project-local only when the workflow depends
  on installed project files such as `$RIG_DIR`, hooks, task cards, or manifest
  state.
- For stealth/external installs, docs should say `$RIG_DIR` for Rig memory,
  tasks, reports, and processes. Use `.rig/` only when describing repo/local
  tracking or template source paths.

## Options

### Option A — Keep `CLAUDE.md` canonical

Keep the current source of truth and document that `CLAUDE.md` is a compatibility
filename, not proof of a Claude dependency.

Pros:

- Lowest migration risk.
- Native Claude behavior stays unchanged.
- Codex-only installs already work.

Cons:

- Keeps a confusing Claude-named file in Codex-only projects.
- Leaves provider-neutral settings coupled to a provider-specific filename.
- Does not address the product expectation that Codex-only users should not need
  Claude-branded project surfaces.

### Option B — Make `AGENTS.md` canonical

Use `AGENTS.md` as the canonical project brain and generate/sync `CLAUDE.md` for
Claude Code compatibility.

Pros:

- Codex has native precedence for `AGENTS.md`.
- User-facing filename is more provider-neutral than `CLAUDE.md`.

Cons:

- `AGENTS.md` can shadow `CLAUDE.md`, so drift becomes dangerous unless sync is
  enforced.
- Claude Code still needs `CLAUDE.md`, so this adds an adapter file rather than
  removing provider-specific surfaces.
- Existing installs require careful migration and conflict handling.

### Option C — Make a Rig-owned neutral brain canonical

Use a neutral Rig source such as `.rig/brain.md` or `.rig/project.md`, then
generate provider-native adapters (`CLAUDE.md`, `AGENTS.md`, or fallback config)
from that source.

Pros:

- Cleanest ownership model: Rig has one provider-neutral source and
  provider-specific adapters.
- Existing provider-native files can become generated or shim surfaces.
- Provider-neutral settings can move out of `CLAUDE.md` parsing.

Cons:

- Highest implementation complexity.
- Requires a migration tool that preserves user customizations.
- Stealth/external installs need careful `.rigpath` and git-exclusion handling.

## Recommendation

Do not rename or replace `CLAUDE.md` in one step. Implement a two-phase
migration:

1. Introduce `.rig/project.md` as the neutral canonical project-brain source
   for provider-neutral project context, imports, and settings currently read
   from `CLAUDE.md`, while continuing to generate or preserve provider-native
   adapter files.
2. After adapters and doctor gates prove stable, allow fresh Codex-only installs
   to edit `.rig/project.md` as the canonical file and receive generated
   `AGENTS.md` / `CLAUDE.md` adapters as selected by installed agent targets.

This keeps Claude Code compatibility intact while giving Codex-only projects a
credible path away from a Claude-named source of truth.

## Chosen Path And Schema

Canonical source:

```text
.rig/project.md
```

Minimum frontmatter schema:

```yaml
---
schema_version: 1
source: rig-project-brain
project_name: Example
base_branch: main
issue_tracking: github
agent_targets:
  - claude
  - codex
adapters:
  claude: CLAUDE.md
  codex: AGENTS.md
---
```

Body content remains Markdown and carries the provider-neutral project brain:
what the project is, stack, repo structure, conventions, context-loading rules,
off-limits paths, and `@.rig/rules/*` imports. Provider-specific delivery files
may add thin native wrappers, but they must not introduce independent policy.

## Conflict Precedence

1. `AGENTS.override.md` is always user-owned and highest precedence for Codex
   runtime because Codex treats it as an explicit local override. The Rig should
   report that it shadows generated adapters, never overwrite it.
2. `.rig/project.md` is the canonical Rig-managed project brain once a project
   has migrated. Provider-neutral settings and docs should read from it first.
3. Generated `AGENTS.md` and `CLAUDE.md` are provider adapters. If their
   manifest metadata proves they are unmodified generated files, upgrade may
   refresh them from `.rig/project.md`. If customized, guarded convergence or
   manual review is required.
4. Pre-migration `CLAUDE.md` remains canonical until `.rig/project.md` exists
   with valid schema metadata and the manifest records the migration. This
   prevents old projects from silently switching sources.
5. `.codex/config.toml` fallback is delivery configuration only. It must point
   Codex at the selected adapter and must not become a project-brain source of
   truth.
6. `.rig/memory/*` remains session memory, not canonical project identity. It
   may supplement context loading but must not override `.rig/project.md`.

## Required Implementation Tickets

1. Add `.rig/project.md` template, manifest ownership metadata, and schema
   validation.
2. Add migration/convergence from existing `CLAUDE.md` into `.rig/project.md`.
3. Generate provider-native adapters without overwriting user customizations.
4. Move provider-neutral setting reads in `bin/rig`, hooks, and commands away
   from hardcoded `CLAUDE.md` parsing.
5. Update doctor gates to report source-of-truth drift and adapter health.
6. Update docs/tests for Claude-only, Codex-only, and combined targets.

## Validation Requirements

- Fresh install: Claude-only, Codex-only, both, and none.
- Upgrade: old `CLAUDE.md`-only project with user customizations.
- Stealth/external/repo tracking modes.
- Codex `AGENTS.md` precedence and fallback behavior.
- Claude Code compatibility after generated adapter updates.
- Doctor gates for missing, stale, divergent, and shadowing instruction files.

## Non-Goals

- Do not remove Claude Code support.
- Do not force existing projects to rename `CLAUDE.md` immediately.
- Do not make independently maintained Claude and Codex project brains.
- Do not change command-source generation as part of the initial spike.
