#!/usr/bin/env python3
"""Render ``~/.codex/config.toml`` from the tracked base plus local state.

Codex writes its own configuration: every project it trusts and every hook hash
it accepts is recorded back into ``config.toml``.  That state names absolute
paths and file digests, so it is meaningless on another host and changes
constantly.  Linking the tracked file into ``~/.codex`` therefore turned a
checkout into Codex's scratch space.

The live file is a physical file Codex owns, and this renderer keeps the tracked
settings authoritative over it with one rule:

    the rendered file is the tracked base, followed by every top-level table
    block of the live file whose header the base does not define.

No allowlist of "local" tables is needed.  The base wins on everything it
declares, and anything Codex invents -- trust entries, hook hashes,
marketplaces, plugins, tables that do not exist yet -- survives untouched.

Exit codes follow the compute-ai-skills installers:

    0   the live file already matches the render
    1   the live file was rendered, or would be under --check
    2   refused: unreadable, malformed, or not a regular file
"""

from __future__ import annotations

import argparse
import os
import sys
import tomllib
from pathlib import Path

SEPARATOR = "# Machine-local state written by Codex; deliberately not tracked."


class RefusedError(Exception):
    """A condition that must stop the run instead of writing anything."""


def read_text(path: Path, label: str) -> str:
    """Return the UTF-8 text of a regular file, refusing anything else."""
    if path.is_symlink() or not path.is_file():
        raise RefusedError(f"{label} is not a regular file: {path}")
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise RefusedError(f"{label} is unreadable: {error}") from error


def parse_toml(text: str, label: str, path: Path) -> None:
    """Refuse text that is not valid TOML."""
    try:
        tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise RefusedError(f"{label} is not valid TOML: {path}: {error}") from error


def table_header(line: str) -> str | None:
    """Return the normalized header of a table line, or None for other lines.

    Only a line whose first non-space character opens a bracket starts a table.
    A bracket inside a value belongs to that value, and a leading space is not
    idiomatic TOML, so neither is treated as a header here.
    """
    if not line.startswith("["):
        return None
    end = line.find("]")
    if end == -1:
        return None
    header = line[: end + 1]
    if header.startswith("[["):
        # An array-of-tables element needs its closing "]]".
        if not line.startswith("[[") or not line[: end + 2].endswith("]]"):
            return None
        header = line[: end + 2]
    return header.strip()


def split_blocks(text: str) -> tuple[str, list[tuple[str, str]]]:
    """Split TOML text into its preamble and its (header, block) pairs."""
    preamble: list[str] = []
    blocks: list[tuple[str, list[str]]] = []
    for line in text.splitlines(keepends=True):
        header = table_header(line)
        if header is None:
            (blocks[-1][1] if blocks else preamble).append(line)
            continue
        blocks.append((header, [line]))
    return "".join(preamble), [(header, "".join(body)) for header, body in blocks]


def render(base_text: str, live_text: str) -> str:
    """Return the base followed by the live blocks the base does not define."""
    _, base_blocks = split_blocks(base_text)
    base_headers = {header for header, _ in base_blocks}
    _, live_blocks = split_blocks(live_text)
    preserved = [block for header, block in live_blocks if header not in base_headers]
    rendered = base_text
    if not preserved:
        return rendered
    if not rendered.endswith("\n"):
        rendered += "\n"
    return f"{rendered}\n{SEPARATOR}\n\n" + "".join(preserved)


def write_atomically(path: Path, text: str) -> None:
    """Replace the file's contents through a same-directory temporary file."""
    temporary = path.with_name(f"{path.name}.render.{os.getpid()}")
    try:
        temporary.write_text(text, encoding="utf-8")
        temporary.chmod(0o600)
        os.replace(temporary, path)
    except OSError as error:
        temporary.unlink(missing_ok=True)
        raise RefusedError(f"could not write {path}: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, type=Path, help="tracked base config")
    parser.add_argument("--target", required=True, type=Path, help="live Codex config")
    parser.add_argument(
        "--check",
        action="store_true",
        help="report whether the target matches the render, without writing",
    )
    arguments = parser.parse_args()

    try:
        base_text = read_text(arguments.base, "base configuration")
        parse_toml(base_text, "base configuration", arguments.base)
        live_text = read_text(arguments.target, "Codex configuration")
        parse_toml(live_text, "Codex configuration", arguments.target)
        rendered = render(base_text, live_text)
        parse_toml(rendered, "rendered configuration", arguments.target)
        if rendered == live_text:
            print(f"Codex configuration is aligned: {arguments.target}")
            return 0
        if arguments.check:
            print(f"repairable: would render {arguments.target} from {arguments.base}")
            return 1
        write_atomically(arguments.target, rendered)
        print(f"rendered {arguments.target} from {arguments.base}")
        return 1
    except RefusedError as error:
        print(f"refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
