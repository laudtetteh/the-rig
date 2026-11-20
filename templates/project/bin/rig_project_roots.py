"""Read the user-owned project discovery roots without changing them."""

import json
import os
import stat
from pathlib import Path


class RootsConfigError(ValueError):
    """The user selected a roots source that cannot be interpreted safely."""


def _paths(values):
    if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
        raise RootsConfigError("projects_roots must be a list of absolute paths")
    roots = []
    for value in values:
        if not value or not Path(value).is_absolute():
            raise RootsConfigError("projects_roots must contain absolute paths")
        path = Path(value)
        if path not in roots:
            roots.append(path)
    return roots


def safe_directory(path):
    for part in (path, *path.parents):
        try:
            if not stat.S_ISDIR(part.lstat().st_mode):
                return False
        except OSError:
            return False
    return True


def read_project_roots(home=None, environ=None):
    """Return (roots, source, missing roots).

    A nonempty RIG_PROJECTS_ROOTS overrides config, using os.pathsep. An existing
    config, including an empty list, suppresses the legacy ~/code fallback.
    """
    home = Path.home() if home is None else Path(home)
    environ = os.environ if environ is None else environ
    raw = environ.get("RIG_PROJECTS_ROOTS")
    if raw is not None:
        if not raw:
            raise RootsConfigError("RIG_PROJECTS_ROOTS is empty")
        roots = _paths(raw.split(os.pathsep))
        source = "environment"
    else:
        config = home / ".rig" / "config.json"
        if config.is_symlink():
            raise RootsConfigError("config.json must be a regular file")
        if config.exists():
            try:
                if not config.is_file() or config.stat().st_size > 65536:
                    raise RootsConfigError("config.json must be a regular file under 64 KiB")
            except OSError as exc:
                raise RootsConfigError("config.json cannot be inspected") from exc
            try:
                data = json.loads(config.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError) as exc:
                raise RootsConfigError("config.json is not valid JSON") from exc
            if (not isinstance(data, dict) or type(data.get("schema_version")) is not int
                    or data["schema_version"] != 1):
                raise RootsConfigError("config.json requires schema_version 1")
            roots = _paths(data.get("projects_roots"))
            source = "config"
        else:
            legacy = home / "code"
            roots = [legacy] if legacy.exists() or legacy.is_symlink() else []
            source = "legacy" if roots else "none"
    missing = []
    for path in roots:
        if not path.exists() and not path.is_symlink():
            missing.append(str(path))
        elif source != "legacy" and not safe_directory(path):
            raise RootsConfigError("project root is not a safe directory: " + str(path))
    return roots, source, missing
