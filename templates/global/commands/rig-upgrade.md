# Command: /rig-upgrade

Run The Rig upgrade workflow from the latest local installer source, not from a
possibly stale project-installed command.

## Global-first bootstrap

1. Read the flags before resolving a project checkout. If the user passed
   `--version` or `--scope=global`, a project checkout is optional. Do not call
   `git rev-parse --show-toplevel` until the delegated latest command actually
   needs project scope.

```bash
SCOPE="both"
VERSION_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --version) VERSION_ONLY=true ;;
    --scope=*) SCOPE="${arg#--scope=}" ;;
  esac
done
```

2. Resolve the target project only for project or both scope:

```bash
if [[ "$VERSION_ONLY" != true && "$SCOPE" != "global" ]]; then
  REPO=$(git rev-parse --show-toplevel)
fi
```

3. Resolve the preferred installer source:

```bash
if [[ -n "${RIG_INSTALLER_SRC:-}" && -f "$RIG_INSTALLER_SRC/install.sh" ]]; then
  INSTALLER_SRC="$RIG_INSTALLER_SRC"
else
  INSTALLER_SRC="$HOME/tools/the-rig"
fi
```

If `$INSTALLER_SRC/install.sh` is missing, stop and tell the user the installer
source is unavailable. Do not continue from the project-local command.

4. Check which branch the installer checkout is on before refreshing it. Never
   switch branches silently — a `RIG_INSTALLER_SRC` checkout on a feature
   branch may be deliberate:

```bash
INSTALLER_IS_GIT=false
INSTALLER_BRANCH=""
if git -C "$INSTALLER_SRC" rev-parse --git-dir >/dev/null 2>&1; then
  INSTALLER_IS_GIT=true
  INSTALLER_BRANCH=$(git -C "$INSTALLER_SRC" branch --show-current 2>/dev/null || echo "")
fi
```

- If `$INSTALLER_IS_GIT` is `false`: there is nothing to refresh; continue
  with the checkout as-is.
- If `$INSTALLER_BRANCH` is empty (detached HEAD): warn that the installer
  source is detached and ask whether to continue from it unchanged. Wait for
  the user's response; stop if they decline.
- If `$INSTALLER_BRANCH` is not `main`: say exactly —
  > "⚠️ Installer source `$INSTALLER_SRC` is on branch '`$INSTALLER_BRANCH`',
  > not `main`. Upgrading from a non-stable branch may install unreviewed
  > changes. Switch to `main` and pull, or proceed on '`$INSTALLER_BRANCH`'
  > as-is?"
  Wait for the user's response. Only if they choose to switch, run:

```bash
git -C "$INSTALLER_SRC" checkout main && git -C "$INSTALLER_SRC" pull --ff-only origin main
```

  If they choose to proceed as-is, do not checkout or pull (pulling `main`
  into another branch would merge unrelated history into it).
- If `$INSTALLER_BRANCH` is `main`: refresh it:

```bash
git -C "$INSTALLER_SRC" pull --ff-only origin main
```

If a checkout or pull fails, stop and report the failure. Do not run a project
upgrade from stale command text unless the user explicitly tells you to proceed.

5. Export the resolved installer source so the delegated latest project command
   cannot silently switch to another checkout:

```bash
export RIG_INSTALLER_SRC="$INSTALLER_SRC"
```

6. Read and follow the latest project upgrade command from:

```bash
$INSTALLER_SRC/templates/project/.claude/commands/rig-upgrade.md
```

Use that file as the authoritative workflow for this run, including all flags
the user passed to this command. The project-installed command or generated
skill file is only a fallback/shim and must not override the refreshed
installer-source command.

## Safety

- Preserve user-owned files and customized Rig-owned files according to the
  refreshed command and installer behavior.
- For Codex, use the generated global skill exactly the same way: refresh
  `$INSTALLER_SRC`, then follow the latest project command reference from the
  installer checkout.
- After the project layer converges, the normal upgrade workflow may update the
  project-level command/skill copies so future invocations have this bootstrap.
