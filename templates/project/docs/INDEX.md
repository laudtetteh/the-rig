# Docs index

One-liner per file. Keep this current when a doc is added, removed, or substantially changes scope.

## Taxonomy

- `features/` — product feature traces only: entry points, flow, data model,
  business rules, and gotchas for a user-facing or business-critical feature.
- `runbooks/` — repeatable operational procedures.
- `reports/` — one-off validation, audit, incident, or status reports.
- `spikes/` — research packages and ticket-specific investigation artifacts.
- `agent-ops/` — Rig, Claude, Codex, browser, MCP, connector, or agent operating notes.
- `records/` — durable project records that do not fit the categories above.

Do not use `features/` as a catch-all docs bucket. When a document is not a
feature trace, choose the closest category above or create a project-specific
category and add it to this index.

| File | What it covers |
|---|---|
| [`features/README.md`](features/README.md) | Index of feature documentation (per-feature end-to-end traces) |
