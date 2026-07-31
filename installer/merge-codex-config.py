#!/usr/bin/env python3
"""Safely add CLAUDE.md to Codex's project instruction fallbacks."""

import argparse
import json
import os
import pathlib
import re
import sys
import tempfile

try:
    import tomllib
except ImportError:  # Python 3.9 compatibility path is exercised on macOS.
    tomllib = None


KEY = "project_doc_fallback_filenames"


def first_table_offset(text):
    """Return the first TOML table header offset, rejecting ambiguous headers."""
    offset = 0
    for line in text.splitlines(keepends=True):
        stripped = line.lstrip(" \t")
        if not stripped.startswith("["):
            offset += len(line)
            continue
        opening = 2 if stripped.startswith("[[") else 1
        index = opening
        quote = None
        escaped = False
        closing = None
        while index < len(stripped):
            char = stripped[index]
            if quote:
                if escaped:
                    escaped = False
                elif quote == '"' and char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
            elif char in "\"'":
                quote = char
            elif char == "]":
                if opening == 1 or stripped[index : index + 2] == "]]":
                    closing = index + opening
                    break
            index += 1
        if closing is None or quote:
            raise ValueError("malformed or ambiguous TOML table header")
        remainder = stripped[closing:].strip()
        if remainder and not remainder.startswith("#"):
            raise ValueError("malformed or ambiguous TOML table header")
        inner = stripped[opening : closing - opening].strip()
        if not inner:
            raise ValueError("empty TOML table header")
        return offset + len(line) - len(stripped)
    return None


def parse_string_array(source):
    values = []
    index = 1
    while index < len(source) - 1:
        while index < len(source) - 1 and source[index] in " \t\r\n,":
            index += 1
        if index < len(source) - 1 and source[index] == "#":
            newline = source.find("\n", index)
            index = len(source) - 1 if newline < 0 else newline + 1
            continue
        if index >= len(source) - 1:
            break
        quote = source[index]
        if quote not in "\"'":
            raise ValueError(f"{KEY} must contain only quoted strings")
        index += 1
        start = index
        escaped = False
        while index < len(source) - 1:
            char = source[index]
            if quote == '"' and escaped:
                escaped = False
            elif quote == '"' and char == "\\":
                escaped = True
            elif char == quote:
                break
            index += 1
        if index >= len(source) - 1:
            raise ValueError(f"unterminated string in {KEY}")
        raw = source[start:index]
        if quote == '"':
            try:
                value = json.loads('"' + raw + '"')
            except json.JSONDecodeError as exc:
                raise ValueError(f"invalid string in {KEY}: {exc}") from exc
        else:
            value = raw
        values.append(value)
        index += 1
        while index < len(source) - 1 and source[index] in " \t\r\n":
            index += 1
        if index < len(source) - 1 and source[index] not in ",#":
            raise ValueError(f"expected a comma in {KEY}")
    return values


def assignment_span(text):
    matches = list(re.finditer(rf"(?m)^[ \t]*{KEY}[ \t]*=", text))
    if len(matches) > 1:
        raise ValueError(f"multiple {KEY} assignments are ambiguous")
    if not matches:
        return None
    match = matches[0]
    start = match.start()
    index = match.end()
    while index < len(text) and text[index].isspace():
        index += 1
    if index >= len(text) or text[index] != "[":
        raise ValueError(f"{KEY} must be a TOML array")
    depth = 0
    quote = None
    escaped = False
    for position in range(index, len(text)):
        char = text[position]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\" and quote == '"':
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in "\"'":
            quote = char
        elif char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                end = position + 1
                while end < len(text) and text[end] in " \t":
                    end += 1
                if end < len(text) and text[end] == "#":
                    newline = text.find("\n", end)
                    end = len(text) if newline < 0 else newline
                return start, end, index, position + 1
    raise ValueError(f"unterminated {KEY} array")


def merged_text(text):
    span = assignment_span(text)
    table_offset = first_table_offset(text)
    if span and table_offset is not None and span[0] > table_offset:
        raise ValueError(f"{KEY} must be a top-level setting")
    use_tomllib = tomllib is not None and os.environ.get("_RIG_TEST_NO_TOMLLIB") != "1"
    if use_tomllib:
        try:
            data = tomllib.loads(text)
        except tomllib.TOMLDecodeError as exc:
            raise ValueError(f"existing Codex config is invalid TOML: {exc}") from exc
        values = data.get(KEY)
    elif span:
        values = parse_string_array(text[span[2] : span[3]])
    else:
        values = None
    if values is not None and (not isinstance(values, list) or any(not isinstance(item, str) for item in values)):
        raise ValueError(f"{KEY} must contain only strings")
    values = list(values or [])
    if "CLAUDE.md" in values:
        return text, False
    values.append("CLAUDE.md")
    assignment = f"{KEY} = {json.dumps(values, ensure_ascii=False)}"
    if span:
        result = text[: span[0]] + assignment + text[span[1] :]
    else:
        insertion = table_offset if table_offset is not None else len(text)
        prefix = text[:insertion]
        suffix = text[insertion:]
        separator = "" if not prefix or prefix.endswith("\n") else "\n"
        result = prefix + separator + assignment + "\n" + suffix
    if use_tomllib:
        try:
            tomllib.loads(result)
        except tomllib.TOMLDecodeError as exc:
            raise ValueError(f"merged Codex config would be invalid TOML: {exc}") from exc
    return result, True


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".config.toml.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if path.exists():
            os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=pathlib.Path)
    args = parser.parse_args()
    try:
        original = args.path.read_text(encoding="utf-8") if args.path.exists() else ""
        result, changed = merged_text(original)
        if changed:
            atomic_write(args.path, result)
        print("updated" if changed else "unchanged")
        return 0
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"Cannot merge Codex project config: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
