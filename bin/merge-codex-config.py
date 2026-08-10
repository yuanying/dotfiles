#!/usr/bin/env python3

"""Apply the host-specific Codex theme without rewriting unrelated TOML."""

import json
import os
from pathlib import Path
import re
import sys
import tempfile
import tomllib


TUI_SECTION = re.compile(r"^\s*\[tui\]\s*(?:#.*)?$")
ANY_SECTION = re.compile(r"^\s*\[")
THEME_KEY = re.compile(r"^(\s*)theme\s*=.*$")


def read_theme(path: Path) -> str | None:
    with path.open("rb") as source:
        theme = tomllib.load(source).get("tui", {}).get("theme")
    if theme is not None and not isinstance(theme, str):
        raise ValueError(f"{path}: tui.theme must be a string")
    return theme


def update_theme(text: str, theme: str) -> str:
    if text.strip():
        tomllib.loads(text)

    lines = text.splitlines(keepends=True)
    section_start = next(
        (index for index, line in enumerate(lines) if TUI_SECTION.match(line)),
        None,
    )
    value = json.dumps(theme)

    if section_start is None:
        separator = "" if not text or text.endswith("\n\n") else "\n"
        return f"{text}{separator}[tui]\ntheme = {value}\n"

    section_end = next(
        (
            index
            for index in range(section_start + 1, len(lines))
            if ANY_SECTION.match(lines[index])
        ),
        len(lines),
    )
    for index in range(section_start + 1, section_end):
        match = THEME_KEY.match(lines[index])
        if match:
            newline = "\n" if lines[index].endswith("\n") else ""
            lines[index] = f"{match.group(1)}theme = {value}{newline}"
            return "".join(lines)

    if not lines[section_start].endswith("\n"):
        lines[section_start] += "\n"
    lines.insert(section_start + 1, f"theme = {value}\n")
    return "".join(lines)


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode if path.exists() else None
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=path.parent, delete=False
        ) as temporary:
            temporary.write(text)
            temporary_name = temporary.name
        if mode is not None:
            os.chmod(temporary_name, mode)
        os.replace(temporary_name, path)
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: merge-codex-config.py TARGET COMMON_CONFIG HOST_CONFIG"
        )

    target, common, host = map(Path, sys.argv[1:])
    theme = read_theme(host) or read_theme(common)
    if theme is None:
        raise SystemExit("neither config defines tui.theme")

    current = target.read_text(encoding="utf-8") if target.exists() else ""
    updated = update_theme(current, theme)
    if updated != current:
        atomic_write(target, updated)


if __name__ == "__main__":
    main()
