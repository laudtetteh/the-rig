# Command: /rig-upgrade

Run The Rig upgrade workflow from the latest local installer source, not from a
possibly stale project-installed command.

## Global-first bootstrap

1. Resolve the target project:

```bash
REPO=$(git rev-parse --show-toplevel)
```

2. Resolve the preferred installer source:

```bash
if [[ -n "${RIG_INSTALLER_SRC:-}" && -f "$RIG_INSTALLER_SRC/install.sh" ]]; then
  INSTALLER_SRC="$RIG_INSTALLER_SRC"
else
  INSTALLER_SRC="$HOME/tools/the-rig"
fi
```

If `$INSTALLER_SRC/install.sh` is missing, stop and tell the user the installer
source is unavailable. Do not continue from the project-local command.

3. Refresh the installer source before using any upgrade instructions from it:

```bash
if [[ -d "$INSTALLER_SRC/.git" ]]; then
  git -C "$INSTALLER_SRC" checkout main
  git -C "$INSTALLER_SRC" pull --ff-only origin main
fi
```

If the checkout or pull fails, stop and report the failure. Do not run a project
upgrade from stale command text unless the user explicitly tells you to proceed.

4. Read and follow the latest project upgrade command from:

```bash
$INSTALLER_SRC/templates/project/.claude/commands/rig-upgrade.md
```

Use that file as the authoritative workflow for this run, including all flags
the user passed to this command. The project-installed `/rig-upgrade` or
`$rig-upgrade` file is only a fallback/shim and must not override the refreshed
installer-source command.

## Safety

- Preserve user-owned files and customized Rig-owned files according to the
  refreshed command and installer behavior.
- For Codex, use the generated global skill exactly the same way: refresh
  `$INSTALLER_SRC`, then follow the latest project command reference from the
  installer checkout.
- After the project layer converges, the normal upgrade workflow may update the
  project-level command/skill copies so future invocations have this bootstrap.
