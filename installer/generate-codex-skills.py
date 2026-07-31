#!/usr/bin/env python3
"""Generate Codex repository skills from selected Rig command templates."""

from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path
from typing import Optional


def rewrite_invocations(body: str, command_names: set[str]) -> str:
    """Rewrite only known Rig slash-command tokens to Codex skill invocations."""
    if not command_names:
        return body
    names = "|".join(sorted(map(re.escape, command_names), key=len, reverse=True))
    pattern = re.compile(rf"(?<![A-Za-z0-9_./-])/({names})(?![A-Za-z0-9_-])")
    return pattern.sub(r"$\1", body)


def copy_project_skills(output: Path, skills_source: Optional[Path]) -> None:
    """Copy complete Claude skill trees without flattening relative paths."""
    if skills_source is None or not skills_source.is_dir():
        return
    for source in sorted(path for path in skills_source.rglob("*") if path.is_file()):
        destination = output / source.relative_to(skills_source)
        if destination.exists():
            raise ValueError(f"Codex skill collision: {destination.relative_to(output)}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)


def generate_global_skills(output: Path, source: Optional[Path]) -> None:
    """Convert legacy flat global Rig skills into Codex user skills."""
    if source is None or not source.is_dir():
        return
    for path in sorted(source.glob("*.md")):
        destination = output / path.stem / "SKILL.md"
        destination.parent.mkdir(parents=True, exist_ok=True)
        body = path.read_text().replace(
            f"~/.claude/skills/{path.name}", f"~/.agents/skills/{path.stem}/SKILL.md"
        )
        destination.write_text(
            "---\n"
            f"name: {path.stem}\n"
            f"description: Apply The Rig {path.stem} workflow.\n"
            "---\n\n"
            + body
        )


def generate(
    output: Path, sources: list[Path], base_branch: str, skills_source: Optional[Path]
) -> None:
    all_commands = {path.stem for path in sources[0].parent.glob("*.md")} if sources else set()
    for source in sources:
        name = source.stem
        skill_dir = output / name
        references = skill_dir / "references"
        references.mkdir(parents=True, exist_ok=True)

        body = source.read_text()
        body = body.replace("[BASE_BRANCH]", base_branch)
        body = rewrite_invocations(body, all_commands)
        (references / "command.md").write_text(body)

        skill = (
            "---\n"
            f"name: {name}\n"
            f"description: Run The Rig {name} workflow for this repository.\n"
            "---\n\n"
            f"# {name}\n\n"
            "Follow the complete workflow in [the command reference](references/command.md).\n"
        )
        (skill_dir / "SKILL.md").write_text(skill)
    copy_project_skills(output, skills_source)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--base-branch", required=True)
    parser.add_argument("--skills-source", type=Path)
    parser.add_argument("--global-skills-source", type=Path)
    parser.add_argument("sources", nargs="*", type=Path)
    args = parser.parse_args()
    generate(args.output, args.sources, args.base_branch, args.skills_source)
    generate_global_skills(args.output, args.global_skills_source)


if __name__ == "__main__":
    main()
