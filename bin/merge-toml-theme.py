#!/usr/bin/env python3

"""Apply the host-specific theme without rewriting unrelated TOML.

KEY はテーブル 1 段までのドット区切り (例: tui.theme, theme)。
"""

import json
import os
from pathlib import Path
import re
import sys
import tempfile
import tomllib


ANY_SECTION = re.compile(r"^\s*\[")


def section_pattern(section: str) -> re.Pattern[str]:
    return re.compile(rf"^\s*\[{re.escape(section)}\]\s*(?:#.*)?$")


def key_pattern(key: str) -> re.Pattern[str]:
    return re.compile(rf"^(\s*){re.escape(key)}\s*=.*$")


def split_key(key: str) -> tuple[str | None, str]:
    parts = key.split(".")
    if len(parts) == 1:
        return None, parts[0]
    if len(parts) == 2:
        return parts[0], parts[1]
    raise SystemExit(f"{key}: KEY はテーブル 1 段までしか扱えない")


def read_theme(path: Path, key: str) -> str | None:
    section, name = split_key(key)
    with path.open("rb") as source:
        table = tomllib.load(source)
    if section is not None:
        table = table.get(section, {})
    theme = table.get(name)
    if theme is not None and not isinstance(theme, str):
        raise ValueError(f"{path}: {key} must be a string")
    return theme


def find_section_end(lines: list[str], section_start: int) -> int:
    return next(
        (
            index
            for index in range(section_start + 1, len(lines))
            if ANY_SECTION.match(lines[index])
        ),
        len(lines),
    )


def replace_in_range(
    lines: list[str], start: int, end: int, name: str, value: str
) -> bool:
    pattern = key_pattern(name)
    for index in range(start, end):
        match = pattern.match(lines[index])
        if match:
            newline = "\n" if lines[index].endswith("\n") else ""
            lines[index] = f"{match.group(1)}{name} = {value}{newline}"
            return True
    return False


def update_top_level(lines: list[str], text: str, name: str, value: str) -> str:
    # テーブルの外、つまり最初のテーブル見出しより前だけが top level。
    first_section = next(
        (index for index, line in enumerate(lines) if ANY_SECTION.match(line)),
        None,
    )
    if replace_in_range(lines, 0, first_section or len(lines), name, value):
        return "".join(lines)

    if first_section is None:
        separator = "" if not text or text.endswith("\n") else "\n"
        return f"{text}{separator}{name} = {value}\n"

    # 見出しの前に空行があればその手前に差し込み、無ければ空行ごと足す。
    if first_section > 0 and not lines[first_section - 1].strip():
        lines.insert(first_section - 1, f"{name} = {value}\n")
    else:
        lines.insert(first_section, f"{name} = {value}\n")
        lines.insert(first_section + 1, "\n")
    return "".join(lines)


def update_section(
    lines: list[str], text: str, section: str, name: str, value: str
) -> str:
    section_start = next(
        (
            index
            for index, line in enumerate(lines)
            if section_pattern(section).match(line)
        ),
        None,
    )

    if section_start is None:
        separator = "" if not text or text.endswith("\n\n") else "\n"
        return f"{text}{separator}[{section}]\n{name} = {value}\n"

    section_end = find_section_end(lines, section_start)
    if replace_in_range(lines, section_start + 1, section_end, name, value):
        return "".join(lines)

    if not lines[section_start].endswith("\n"):
        lines[section_start] += "\n"
    lines.insert(section_start + 1, f"{name} = {value}\n")
    return "".join(lines)


def update_theme(text: str, key: str, theme: str) -> str:
    if text.strip():
        tomllib.loads(text)

    section, name = split_key(key)
    lines = text.splitlines(keepends=True)
    value = json.dumps(theme)

    if section is None:
        return update_top_level(lines, text, name, value)
    return update_section(lines, text, section, name, value)


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
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: merge-toml-theme.py KEY TARGET COMMON_CONFIG HOST_CONFIG"
        )

    key = sys.argv[1]
    target, common, host = map(Path, sys.argv[2:])
    theme = read_theme(host, key) or read_theme(common, key)
    if theme is None:
        raise SystemExit(f"neither config defines {key}")

    current = target.read_text(encoding="utf-8") if target.exists() else ""
    updated = update_theme(current, key, theme)
    if updated != current:
        atomic_write(target, updated)


if __name__ == "__main__":
    main()
