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
    match = re.search(rf"(?m)^[ \t]*{KEY}[ \t]*=", text)
    if not match:
        return None
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
    table = re.search(r"(?m)^[ \t]*\[{1,2}[A-Za-z0-9_.\"'-]+\]{1,2}[ \t]*(?:#.*)?$", text)
    if span and table and span[0] > table.start():
        raise ValueError(f"{KEY} must be a top-level setting")
    if tomllib is not None:
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
        insertion = table.start() if table else len(text)
        prefix = text[:insertion]
        suffix = text[insertion:]
        separator = "" if not prefix or prefix.endswith("\n") else "\n"
        result = prefix + separator + assignment + "\n" + suffix
    if tomllib is not None:
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
