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

1. Introduce a neutral canonical metadata/brain source under `.rig/` for
   provider-neutral settings and project-brain content, while continuing to
   generate or preserve provider-native adapter files.
2. After adapters and doctor gates prove stable, allow fresh Codex-only installs
   to prefer `AGENTS.md` or the neutral source without making `CLAUDE.md` the
   edited canonical file.

This keeps Claude Code compatibility intact while giving Codex-only projects a
credible path away from a Claude-named source of truth.

## Required Implementation Tickets

1. Define the neutral source schema and path.
2. Add migration/convergence from existing `CLAUDE.md` into the neutral source.
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
