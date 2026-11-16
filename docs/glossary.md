# The Rig glossary

Short definitions for terms used by the installer and session workflows. [How The Rig works](how-it-works.md) covers the full architecture.

| Term | Meaning | Contract |
|---|---|---|
| **`RIG_DIR`** | The effective Rig data directory for one project. In `repo` or `local` tracking it is the project's `.rig/`; in `external` or `stealth` tracking, `.rigpath` points to the configured path. An `external` path can be inside the checkout. | [Tracking options](customizing.md#keeping-rig-invisible-to-teammates) |
| **Session anchor** | The Rig's UUID for one session record and work segment. One provider conversation can have multiple Rig records over its lifetime; exact identity determines which anchor is current. | [Session identity](../templates/project/.rig/rules/session-identity.md), [continuation](how-it-works.md#session-identity-and-continuation) |
| **Native session ID** | The ID supplied by Claude Code or Codex for its conversation or thread. Rig binds it with the provider and project to resolve the exact session record; a branch name or process ID cannot substitute for it. | [Session identity](../templates/project/.rig/rules/session-identity.md) |
| **Tracking mode** | The installer's `repo`, `local`, `external`, or `stealth` choice for data placement and Git exclusions. `external` uses the selected path, whose Git visibility depends on its location; `stealth` hides project adapters. This is separate from which agent is installed. | [Tracking options](customizing.md#keeping-rig-invisible-to-teammates) |
| **Manifest base** | The previously accepted content hash for a Rig-owned file. Upgrade compares it with the destination and proves a historical merge ancestor by matching rendered template content; `base_revision` only orders that search. | [Manifest behavior](customizing.md#how-it-works-the-manifest), [metadata](customizing.md#manifest-metadata-and-provenance-fields) |
| **Checkpoint** | A small saved view of current work used around context compaction or session recovery. The per-session compact checkpoint differs from the shared `CONTEXT_SNAPSHOT.md` used to orient a new session. | [Session lifecycle](how-it-works.md#session-lifecycle), [memory](how-it-works.md#the-memory-system) |
| **Obligation** | Pending work attached to an exact session, such as wrap or post-merge housekeeping. A shared reminder surfaces it; clearing post-merge requires the pending merge SHA. | [Session identity and repair](../templates/project/.rig/rules/session-identity.md) |
