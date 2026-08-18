#!/usr/bin/env python3

"""Apply the host-specific config without rewriting unrelated TOML.

共通とホスト別の設定に書いてあるキーだけを流し込む (ホスト別が勝つ)。
ツール自身が書き戻すファイルが相手なので、追跡していないキーとコメントは
そのまま残す。扱えるのはテーブル 1 段までのスカラー値とその配列。
"""

import json
import os
from pathlib import Path
import re
import sys
import tempfile
import tomllib


ANY_SECTION = re.compile(r"^\s*\[")

SCALAR_TYPES = (str, bool, int, float)

BARE_KEY = re.compile(r"^[A-Za-z0-9_-]+$")


def section_pattern(section: str) -> re.Pattern[str]:
    return re.compile(rf"^\s*\[{re.escape(section)}\]\s*(?:#.*)?$")


def key_pattern(key: str) -> re.Pattern[str]:
    return re.compile(rf"^(\s*){re.escape(key)}\s*=.*$")


def read_entries(path: Path) -> dict[tuple[str | None, str], object]:
    with path.open("rb") as source:
        table = tomllib.load(source)

    entries: dict[tuple[str | None, str], object] = {}
    for key, value in table.items():
        if isinstance(value, dict):
            for nested_key, nested_value in value.items():
                check_scalar(path, f"{key}.{nested_key}", nested_value)
                entries[(key, nested_key)] = nested_value
            continue
        check_scalar(path, key, value)
        entries[(None, key)] = value
    return entries


def check_scalar(path: Path, key: str, value: object) -> None:
    if isinstance(value, list):
        if all(isinstance(item, SCALAR_TYPES) for item in value):
            return
    elif isinstance(value, SCALAR_TYPES):
        return
    raise SystemExit(
        f"{path}: {key} はテーブル 1 段までのスカラー値かその配列のみ"
    )


def to_toml(value: object) -> str:
    # TOML のスカラーと配列の表記は JSON と同じ (true/false も含む)。
    return json.dumps(value)


def format_key(key: str) -> str:
    # hunk の keybindings のようにドットを含むキーは引用符が要る。
    return key if BARE_KEY.match(key) else json.dumps(key)


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


def update_entry(text: str, section: str | None, name: str, value: object) -> str:
    if text.strip():
        tomllib.loads(text)

    lines = text.splitlines(keepends=True)
    name = format_key(name)
    serialized = to_toml(value)

    if section is None:
        return update_top_level(lines, text, name, serialized)
    return update_section(lines, text, section, name, serialized)


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
            "usage: merge-toml-config.py TARGET COMMON_CONFIG HOST_CONFIG"
        )

    target, common, host = map(Path, sys.argv[1:])
    entries = read_entries(common) | read_entries(host)
    if not entries:
        raise SystemExit(f"{common} と {host} のどちらにもキーが無い")

    current = target.read_text(encoding="utf-8") if target.exists() else ""
    updated = current
    for (section, name), value in entries.items():
        updated = update_entry(updated, section, name, value)
    if updated != current:
        atomic_write(target, updated)


if __name__ == "__main__":
    main()
