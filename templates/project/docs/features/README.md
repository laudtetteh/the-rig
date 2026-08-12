# Feature Documentation

End-to-end traces for business-critical features in this project.
Each doc maps a feature from entry point to render: templates, PHP/code, queries,
data models, business rules, and known gotchas.

`docs/features/` is not a catch-all documentation bucket. Put operational
runbooks in `docs/runbooks/`, one-off audits and validation artifacts in
`docs/reports/`, research packages in `docs/spikes/`, and agent/Rig/browser/MCP
operating notes in `docs/agent-ops/`.

---

## When to read these

- **Before touching code** that overlaps with a documented feature — understand
  the full chain before making a change
- **When a bug surfaces** in a documented area — check the gotchas section first
- **When onboarding** — feature docs are the fastest way to understand how
  non-obvious parts of the system actually work

## When to update these

- **After any PR that changes** a documented feature's data model, query logic,
  render logic, or business rules — run `/refresh-feature-doc <feature>` to
  keep the doc current

## When to create new docs

- **After researching any non-obvious feature** — if you had to read 5+ files
  to understand how something works, future sessions will too. Run
  `/doc-feature <name>` to capture it while the knowledge is fresh.

---

## Index

| Feature | Doc | Last updated |
|---|---|---|
| *(none yet — run `/doc-feature <name>` to create the first one)* | — | — |
