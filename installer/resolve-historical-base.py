#!/usr/bin/env python3
"""Resolve a trusted historical merge base for one customized Rig-owned file.

Issue #560. Supplies the `--base` that installer/merge-*.py have always
accepted but never received (see attempt_convergence_merge() in install.sh and
the "no trusted base" notes in merge-text3way.py / _convergence_common.py).

Why content-addressed rather than version-keyed
-----------------------------------------------
The obvious design is "look the template up at the manifest's recorded
base_revision". Live analysis of a real blocked downstream install
(/Users/beaconavenue/code/4Culture, Rig 1.27.1) disproved that premise: all 16
customized Rig-owned files that the v1.29.0 agent-plan refused are tracked only
in the legacy flat `.rig-manifest`, which records `sha256  path` and nothing
else. base_revision was absent for 16 of 16, so a version-keyed resolver would
have resolved none of them. A content-addressed scan recovered 16/16 exactly --
at v1.14.0-v1.17.0, not the v1.27.1 that base_revision would have claimed had
it been present.

So the manifest's recorded SHA256 is the lookup key, and a candidate base is
accepted only when its rendered content hashes to exactly that value. The base
is therefore *proven*, never *claimed*. base_revision, when present, is used
only to order the scan so the likely tag is tried first.

This also means installer-source worktree dirtiness is deliberately NOT a
refusal reason: every candidate is read from an immutable committed tag object
via `git show <tag>:<path>`, and is then verified by hash equality. Uncommitted
edits in the source checkout cannot influence the result. What *is* required is
that the source is a git work tree exposing this project's release tags.

Rendering
---------
A candidate's raw template bytes are not what landed on disk. The installer
substitutes [REPO_ROOT], [BASE_BRANCH], and [Project Name] after copy (see
rendered_project_template_hash() in install.sh), so the comparison is always
against post-substitution content. Callers pass the project's values; omitted
values leave their placeholder untouched, which is correct for the many
artifacts that contain no placeholder at all.

Generated Codex mirrors
-----------------------
`.agents/skills/<name>/...` and `.codex/skills/<name>/...` are generated, not
copied. Their base is reproduced by replaying the *historical* generator
(installer/generate-codex-skills.py at the candidate tag) over the *historical*
Claude command tree at that same tag -- never inferred from downstream content.

Usage:
    resolve-historical-base.py --source-repo DIR --rel PATH \
        --recorded-hash SHA256 [--hint-revision X.Y.Z] \
        [--repo-root PATH] [--base-branch BRANCH] [--project-name NAME] \
        [--output FILE] [--max-tags N]

Prints one JSON report line to stdout and exits 0 (resolved, base written to
--output when given), 1 (refused, with a precise `reason`), or 2 (I/O failure).
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

TEMPLATE_ROOT = "templates/project"
GENERATOR_PATH = "installer/generate-codex-skills.py"
COMMANDS_DIR = "templates/project/.claude/commands"
_TAG_PATTERN = re.compile(r"^v(\d+)(?:\.(\d+))*$")
_SKILL_PREFIXES = (".agents/skills/", ".codex/skills/")


class Refusal(Exception):
    """Raised with a precise, user-actionable reason. Never a stack trace."""

    def __init__(self, reason, **extra):
        super().__init__(reason)
        self.reason = reason
        self.extra = extra


# ── git plumbing ──────────────────────────────────────────────────────────────

def git_env():
    """Environment with ambient git redirection stripped.

    `git -C <dir>` does NOT override an exported GIT_DIR: with GIT_DIR set,
    every read would silently come from a different repository, breaking this
    module's central claim that candidates are committed objects from the
    installer source.
    """
    env = dict(os.environ)
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        env.pop(name, None)
    return env


def git(source_repo, *args):
    """Run one git command in the source repo, returning (rc, stdout-bytes)."""
    proc = subprocess.run(
        ("git", "-C", source_repo) + args,
        capture_output=True,
        env=git_env(),
        stdin=subprocess.DEVNULL,
    )
    return proc.returncode, proc.stdout


def require_git_source(source_repo):
    if not os.path.isdir(source_repo):
        raise Refusal(
            "installer source is not a directory: %s" % source_repo,
            repair_guidance="Point --source-repo at a git checkout of The Rig.",
        )
    rc, _ = git(source_repo, "rev-parse", "--is-inside-work-tree")
    if rc != 0:
        raise Refusal(
            "installer source is not a git work tree: %s" % source_repo,
            repair_guidance=(
                "Historical bases are read from release tags. Re-run against a "
                "git clone of The Rig rather than an extracted archive."
            ),
        )


def version_key(tag):
    parts = tag.lstrip("v").split(".")
    key = []
    for part in parts:
        try:
            key.append(int(part))
        except ValueError:
            key.append(-1)
    return tuple(key)


def release_tags(source_repo):
    """Release tags, newest version first."""
    rc, out = git(source_repo, "tag", "--list", "v*")
    if rc != 0:
        raise Refusal("could not list tags in the installer source")
    tags = [t for t in out.decode("utf-8", "replace").split() if _TAG_PATTERN.match(t)]
    if not tags:
        raise Refusal(
            "installer source exposes no release tags",
            repair_guidance=(
                "Fetch tags in the installer source (git fetch --tags) so "
                "historical template revisions are reachable."
            ),
        )
    return sorted(tags, key=version_key, reverse=True)


def ordered_candidates(tags, hint_revision):
    """Newest-first, but with the hinted revision tried first when present.

    Ordering is a speed optimization only. Correctness comes from hash
    equality, so a wrong or missing hint can never produce a wrong base.
    """
    if not hint_revision:
        return tags
    hint_tag = hint_revision if hint_revision.startswith("v") else "v" + hint_revision
    if hint_tag not in tags:
        return tags
    return [hint_tag] + [t for t in tags if t != hint_tag]


def show(source_repo, tag, path):
    """Committed bytes of `path` at `tag`, or None when absent there."""
    rc, out = git(source_repo, "show", "%s:%s" % (tag, path))
    return out if rc == 0 else None


def object_ids(source_repo, revs):
    """Resolve many `<tag>:<path>` revs to object ids in one git process.

    A release history is long (The Rig has ~37 tags) but a given template
    usually has only a handful of distinct revisions across all of them.
    Resolving ids in one `cat-file --batch-check` and then deduplicating means
    the expensive work — reading and rendering content — happens once per
    *distinct* revision instead of once per tag.

    Returns a list aligned with `revs`, holding the object id or None.
    """
    if not revs:
        return []
    proc = subprocess.run(
        ("git", "-C", source_repo, "cat-file", "--batch-check"),
        input="\n".join(revs).encode("utf-8") + b"\n",
        capture_output=True,
        env=git_env(),
    )
    if proc.returncode != 0:
        return [None] * len(revs)
    resolved = []
    for line in proc.stdout.decode("utf-8", "replace").splitlines():
        fields = line.split()
        # "<oid> <type> <size>" on success, "<rev> missing" otherwise.
        if len(fields) >= 3 and fields[1] == "blob":
            resolved.append(fields[0])
        else:
            resolved.append(None)
    while len(resolved) < len(revs):
        resolved.append(None)
    return resolved[: len(revs)]


def read_object(source_repo, oid):
    """Bytes of one object id, or None."""
    rc, out = git(source_repo, "cat-file", "blob", oid)
    return out if rc == 0 else None


def tree_id(source_repo, tag, path):
    """Object id of a tree at `tag`, or None when absent."""
    rc, out = git(source_repo, "rev-parse", "%s:%s" % (tag, path))
    if rc != 0:
        return None
    return out.decode("utf-8", "replace").strip() or None


# ── rendering ─────────────────────────────────────────────────────────────────

def renderings(raw, repo_root, base_branch, project_name):
    """Every rendering of `raw` that could legitimately have landed on disk.

    The installer does not substitute uniformly. [BASE_BRANCH] is rewritten
    only in an allowlist of files (_subst_base_branch() in install.sh covers
    CLAUDE.md, ship.md, post-merge.md, and POST_MERGE_WORKFLOW.md),
    [REPO_ROOT] only in settings.json, and [Project Name] only in CLAUDE.md --
    while rendered_project_template_hash() renders any file containing a
    placeholder for *comparison*. Which set applied also varied across the
    releases this resolver scans.

    Rather than hard-coding one release's allowlist and silently failing on
    the others, produce both the raw and the fully-substituted candidate and
    let hash equality decide. Trying more candidates cannot produce a wrong
    base: every one of them still has to hash to the manifest's recorded
    baseline to be accepted. It only widens the set of installs whose base can
    be *proven* rather than guessed.

    Returned newest-intent-first with duplicates removed.
    """
    candidates = [raw]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return candidates  # binary artifact: substitution does not apply
    substituted = text
    # `is not None`, not truthiness: an explicitly empty value is still a
    # substitution the installer performed, and treating it as "not supplied"
    # would leave the placeholder in place and fail to match the baseline.
    if repo_root is not None:
        substituted = substituted.replace("[REPO_ROOT]", repo_root)
    if base_branch is not None:
        substituted = substituted.replace("[BASE_BRANCH]", base_branch)
    if project_name is not None:
        substituted = substituted.replace("[Project Name]", project_name)
    encoded = substituted.encode("utf-8")
    if encoded != raw:
        candidates.append(encoded)
    return candidates


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# ── candidate production ──────────────────────────────────────────────────────

def is_generated_skill(rel):
    return rel.startswith(_SKILL_PREFIXES)


def skill_command_name(rel):
    """`.agents/skills/wrap/SKILL.md` -> ('wrap', 'SKILL.md')."""
    for prefix in _SKILL_PREFIXES:
        if rel.startswith(prefix):
            remainder = rel[len(prefix):]
            name, _, inner = remainder.partition("/")
            if not name or not inner:
                raise Refusal(
                    "generated skill path has no <name>/<artifact> shape: %s" % rel,
                    repair_guidance=(
                        "Only generated skill artifacts under a skill directory "
                        "can be reproduced from a historical Claude command."
                    ),
                )
            return name, inner
    raise Refusal("not a generated skill path: %s" % rel)


def require_safe_rel(rel):
    """Reject a relative path that could escape the template tree.

    `rel` is read from the target project's manifest — the very file whose
    contents this resolver exists to distrust. A `rel` containing `..` would
    otherwise turn `worktree_candidate()` into an arbitrary file read anywhere
    the installer can reach. (Tag-side candidates are already safe: git refuses
    to resolve `templates/project/../x` in a `<tag>:<path>` spec.)
    """
    if not rel or rel.startswith("/") or os.path.isabs(rel):
        raise Refusal(
            "manifest path is not relative: %s" % rel,
            repair_guidance="Repair the manifest entry; its path must be relative.",
        )
    normalized = os.path.normpath(rel)
    if normalized == ".." or normalized.startswith("../") or "\x00" in rel:
        raise Refusal(
            "manifest path escapes the template tree: %s" % rel,
            repair_guidance="Repair the manifest entry; its path must stay inside the project.",
        )


def template_path_for(rel):
    """Map an installed relative path to its template path in the source tree."""
    return "%s/%s" % (TEMPLATE_ROOT, rel)


def copied_candidate(source_repo, tag, rel):
    return show(source_repo, tag, template_path_for(rel))


def generated_candidate(source_repo, tag, rel, base_branch, seen_commands):
    """Reproduce one generated Codex skill artifact at `tag`.

    Replays the historical generator over the historical command tree. Both
    come from the tag, so downstream content never influences the base.

    Appends `tag` to `seen_commands` when the canonical Claude command existed
    at that revision, so the caller can tell "no revision ever had this
    command" from "this particular revision did not".
    """
    name, inner = skill_command_name(rel)

    generator = show(source_repo, tag, GENERATOR_PATH)
    if generator is None:
        return None  # generator did not exist at this tag

    rc, listing = git(source_repo, "ls-tree", "--name-only", "%s:%s" % (tag, COMMANDS_DIR))
    if rc != 0:
        return None
    command_files = [
        n for n in listing.decode("utf-8", "replace").split("\n")
        if n.endswith(".md")
    ]
    if "%s.md" % name not in command_files:
        # Skip this revision rather than aborting the scan. A command can be
        # absent at one tag and present (and provable) at an older one — every
        # skill whose command postdates the earliest tag hits this — so raising
        # here would refuse a base that a later candidate reproduces exactly.
        # Whether *any* revision had the command is decided by the caller.
        return None
    seen_commands.append(tag)

    workdir = tempfile.mkdtemp(prefix=".rig-histbase.")
    try:
        commands_dir = os.path.join(workdir, "commands")
        os.makedirs(commands_dir)
        for filename in command_files:
            blob = show(source_repo, tag, "%s/%s" % (COMMANDS_DIR, filename))
            if blob is None:
                continue
            with open(os.path.join(commands_dir, filename), "wb") as handle:
                handle.write(blob)

        generator_file = os.path.join(workdir, "generate-codex-skills.py")
        with open(generator_file, "wb") as handle:
            handle.write(generator)

        return replay_generator(generator_file, commands_dir, name, inner, base_branch)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def replay_generator(generator_file, commands_dir, name, inner, base_branch):
    """Run one generator over one command tree and return the named artifact."""
    sources = sorted(
        os.path.join(commands_dir, filename)
        for filename in os.listdir(commands_dir)
        if filename.endswith(".md")
    )
    if not sources:
        return None
    output_dir = tempfile.mkdtemp(prefix=".rig-histbase-out.")
    try:
        try:
            proc = subprocess.run(
                [sys.executable, generator_file, "--output", output_dir,
                 "--base-branch", base_branch or "[BASE_BRANCH]"] + sources,
                capture_output=True,
                # A historical generator that hangs or reads stdin would
                # otherwise stall the upgrade, or eat the interactive
                # installer's input.
                stdin=subprocess.DEVNULL,
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if proc.returncode != 0:
            return None
        produced = os.path.join(output_dir, name, inner)
        if not os.path.isfile(produced):
            return None
        with open(produced, "rb") as handle:
            return handle.read()
    finally:
        shutil.rmtree(output_dir, ignore_errors=True)


def generated_from_tree(args, generator_file, commands_dir):
    """Reproduce a generated skill artifact from on-disk generator + commands."""
    name, inner = skill_command_name(args.rel)
    if not os.path.isfile(os.path.join(commands_dir, "%s.md" % name)):
        return None
    return replay_generator(
        generator_file, commands_dir, name, inner, args.base_branch
    )


def worktree_candidate(args, generated):
    """The installer's own checked-out template, as a base candidate.

    Tried before any tag, for two reasons. It is the single most likely base
    in practice -- a file installed at version N whose template has not
    changed since is still customized relative to N -- and resolving it needs
    no tags at all, so convergence keeps working in a shallow clone.

    It is exactly as safe as a tag candidate: the content still has to hash to
    the manifest's recorded baseline before it is accepted.
    """
    if generated:
        generator = os.path.join(args.source_repo, GENERATOR_PATH)
        commands = os.path.join(args.source_repo, COMMANDS_DIR)
        if not os.path.isfile(generator) or not os.path.isdir(commands):
            return None
        return generated_from_tree(args, generator, commands)

    path = os.path.join(args.source_repo, template_path_for(args.rel))
    if not os.path.isfile(path) or os.path.islink(path):
        return None
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError:
        return None


def candidate_contents(args, candidates, generated, seen_commands):
    """Yield (tag, raw-bytes-or-None) for each candidate, skipping repeats.

    Deduplication is what keeps this affordable. A template that never changed
    across 37 releases is read and rendered once, not 37 times; a generated
    skill is replayed once per distinct (generator, command-tree) pair rather
    than once per tag. Tags whose revision was already tried are skipped
    entirely, so `tags_scanned` reports distinct tag revisions examined — the
    number that actually reflects the historical search.
    """
    if generated:
        seen = set()
        for tag in candidates:
            generator = tree_id(args.source_repo, tag, GENERATOR_PATH)
            commands = tree_id(args.source_repo, tag, COMMANDS_DIR)
            if generator is None or commands is None:
                continue
            key = (generator, commands)
            if key in seen:
                continue
            seen.add(key)
            yield tag, generated_candidate(
                args.source_repo, tag, args.rel, args.base_branch, seen_commands
            )
        return

    template = template_path_for(args.rel)
    oids = object_ids(
        args.source_repo, ["%s:%s" % (tag, template) for tag in candidates]
    )
    seen = set()
    for tag, oid in zip(candidates, oids):
        if oid is None or oid in seen:
            continue
        seen.add(oid)
        yield tag, read_object(args.source_repo, oid)


# ── resolution ────────────────────────────────────────────────────────────────

def matches(args, raw):
    """The rendering of `raw` that equals the recorded baseline, or None."""
    if raw is None:
        return None
    for rendered in renderings(
        raw, args.repo_root, args.base_branch, args.project_name
    ):
        if sha256(rendered) == args.recorded_hash:
            return rendered
    return None


def resolve(args):
    require_git_source(args.source_repo)
    require_safe_rel(args.rel)

    generated = is_generated_skill(args.rel)
    if generated:
        # Raises Refusal early for a structurally unusable skill path, before
        # anything is scanned.
        skill_command_name(args.rel)

    scanned = 0
    seen_template = False
    # Tags at which the canonical Claude command existed, for generated skills.
    seen_commands = []

    # The checked-out template first: most likely base, and needs no tags.
    worktree_raw = worktree_candidate(args, generated)
    if worktree_raw is not None:
        seen_template = True
        rendered = matches(args, worktree_raw)
        if rendered is not None:
            return "worktree", rendered, scanned

    try:
        tags = release_tags(args.source_repo)
    except Refusal:
        # No tags is only fatal if the worktree candidate did not already
        # settle it. Re-raise with the template context we now have.
        if seen_template:
            raise Refusal(
                "no release tags, and the current template does not reproduce "
                "the recorded baseline for %s" % args.rel,
                repair_guidance=(
                    "Fetch tags in the installer source (git fetch --tags) so "
                    "historical template revisions become reachable, then "
                    "re-run the upgrade."
                ),
                tags_scanned=scanned,
            )
        raise

    candidates = ordered_candidates(tags, args.hint_revision)
    if args.max_tags and args.max_tags > 0:
        candidates = candidates[: args.max_tags]

    for tag, raw in candidate_contents(args, candidates, generated, seen_commands):
        scanned += 1
        if raw is None:
            continue
        seen_template = True
        rendered = matches(args, raw)
        if rendered is not None:
            return tag, rendered, scanned

    if generated and not seen_commands:
        raise Refusal(
            "generated skill '%s' has no canonical Claude command at any "
            "revision" % skill_command_name(args.rel)[0],
            repair_guidance=(
                "The skill was generated from a command that exists at no "
                "released revision. Regenerate skills with "
                "installer/generate-codex-skills.py instead of merging."
            ),
            tags_scanned=scanned,
        )
    if not seen_template:
        raise Refusal(
            "no historical template exists for %s in the installer source" % args.rel,
            repair_guidance=(
                "This path has no template of record (it may be generated at "
                "install time, or retired). Resolve it manually rather than "
                "merging against a guessed base."
            ),
            tags_scanned=scanned,
        )
    raise Refusal(
        "no historical revision reproduces the recorded baseline for %s" % args.rel,
        repair_guidance=(
            "The manifest baseline does not match any released template "
            "revision, so no base can be proven. Restore the file from "
            ".rig-backup/ and accept the incoming template, or resolve the "
            "differences manually."
        ),
        tags_scanned=scanned,
        recorded_hash=args.recorded_hash,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-repo", required=True)
    parser.add_argument("--rel", required=True)
    parser.add_argument("--recorded-hash", required=True)
    parser.add_argument("--hint-revision")
    parser.add_argument("--repo-root")
    parser.add_argument("--base-branch")
    parser.add_argument("--project-name")
    parser.add_argument("--output")
    parser.add_argument("--max-tags", type=int, default=0)
    args = parser.parse_args()

    if not re.fullmatch(r"[0-9a-f]{64}", args.recorded_hash or ""):
        print(json.dumps({
            "ok": False,
            "reason": "recorded hash is not a SHA256 hex digest",
            "rel": args.rel,
        }, separators=(",", ":")))
        return 1

    try:
        tag, content, scanned = resolve(args)
    except Refusal as refusal:
        doc = {"ok": False, "rel": args.rel, "reason": refusal.reason}
        doc.update(refusal.extra)
        print(json.dumps(doc, separators=(",", ":")))
        return 1
    except OSError as exc:
        print(json.dumps({
            "ok": False, "rel": args.rel, "reason": str(exc),
        }, separators=(",", ":")))
        return 2

    if args.output:
        # Writing the base is as much part of the contract as resolving it: a
        # bare traceback here would print no JSON at all and exit 1, the code
        # reserved for "refused". The caller sends stderr to /dev/null, so it
        # would see a refusal it cannot explain.
        try:
            directory = os.path.dirname(os.path.abspath(args.output)) or "."
            fd, temporary = tempfile.mkstemp(dir=directory, prefix=".rig-histbase.")
            try:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(content)
                os.replace(temporary, args.output)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        except OSError as exc:
            print(json.dumps({
                "ok": False, "rel": args.rel,
                "reason": "could not write the resolved base: %s" % exc,
            }, separators=(",", ":")))
            return 2

    print(json.dumps({
        "ok": True,
        "rel": args.rel,
        "base_tag": tag,
        "tags_scanned": scanned,
        "generated": is_generated_skill(args.rel),
    }, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
