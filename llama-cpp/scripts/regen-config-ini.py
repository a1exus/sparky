#!/usr/bin/env python3
"""Regenerate config.ini for llama.cpp router mode with managed-fields semantics.

Reads tab-separated GGUF inventory from stdin (one per line):
    <section-name>\t<container-model-path>

Writes:
    <config-path>          active sections (one per current GGUF)
    <orphan-path>          removed-GGUF archive (restored verbatim if GGUF returns)

Managed-fields rules:
    - On each run, hf-sync owns the `model =` line of every active section.
    - All other keys are user-editable and preserved verbatim across runs.
    - A new section gets default `ctx-size` and `n-gpu-layers` from CLI args.
    - When a GGUF disappears from the input, its section is moved to the
      orphan archive (kept verbatim). If the GGUF later returns, the archived
      section is restored as-is (preserving any user edits) — except `model`,
      which is rewritten from the current input.
    - A section that isn't in the current input at all (hand-added, or from
      before this run) is kept as-is, not archived, as long as its `model`
      file still exists in the symlink farm — lets a user manually assign a
      short alias to a model sync-router.sh didn't (e.g. a collision loser)
      and have it survive future runs.

Collision reporting: <collisions-path> holds tab-separated
    <basename>\t<comma-joined-repo-list>
lines (produced by sync-router.sh's counting pass). Rendered as a
`# COLLISIONS` block in config.ini's header. Empty/missing file → no block.

Atomic writes: <path>.tmp + os.replace() so concurrent readers never see a
half-written file.
"""

from __future__ import annotations

import configparser
import os
import sys
from pathlib import Path


def _load(path: Path) -> configparser.ConfigParser:
    cp = configparser.ConfigParser()
    cp.optionxform = str  # preserve key case
    if path.exists():
        cp.read(path)
    return cp


def _write_atomic(cp: configparser.ConfigParser, path: Path, header: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w") as f:
        f.write(header)
        cp.write(f)
    os.replace(tmp, path)


def _load_collisions(path: Path) -> list[tuple[str, str]]:
    if not path.exists():
        return []
    collisions: list[tuple[str, str]] = []
    for raw in path.read_text().splitlines():
        if not raw:
            continue
        basename, repos = raw.split("\t", 1)
        collisions.append((basename, repos))
    return collisions


def main() -> int:
    if len(sys.argv) != 7:
        print(
            f"usage: {sys.argv[0]} <config-path> <orphan-path> <ctx-default> "
            "<ngl-default> <symlink-farm-dir> <collisions-path>",
            file=sys.stderr,
        )
        return 64

    config_path = Path(sys.argv[1])
    orphan_path = Path(sys.argv[2])
    ctx_default = sys.argv[3]
    ngl_default = sys.argv[4]
    symlink_farm = Path(sys.argv[5])
    collisions_path = Path(sys.argv[6])

    for p in (config_path, orphan_path):
        if not p.parent.exists():
            print(f"error: parent directory does not exist: {p.parent}", file=sys.stderr)
            return 1

    current: dict[str, str] = {}
    for lineno, raw in enumerate(sys.stdin, 1):
        line = raw.rstrip("\r\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            print(
                f"stdin line {lineno}: expected 2 tab-separated fields, got {len(parts)}: {line!r}",
                file=sys.stderr,
            )
            return 2
        section, model = parts
        current[section] = model

    existing = _load(config_path)
    orphans = _load(orphan_path)
    collisions = _load_collisions(collisions_path)

    new_config = configparser.ConfigParser()
    new_config.optionxform = str
    new_orphans = configparser.ConfigParser()
    new_orphans.optionxform = str

    for section, model in current.items():
        if existing.has_section(section):
            new_config[section] = dict(existing.items(section))
            new_config[section]["model"] = model  # managed field
        elif orphans.has_section(section):
            new_config[section] = dict(orphans.items(section))
            new_config[section]["model"] = model
        else:
            new_config[section] = {
                "model": model,
                "ctx-size": ctx_default,
                "n-gpu-layers": ngl_default,
            }

    for section in existing.sections():
        if section in current:
            continue
        model_value = existing.get(section, "model", fallback="")
        target = symlink_farm / Path(model_value).name if model_value else None
        if target is not None and target.exists():
            # Hand-added or previously-managed section whose GGUF is still
            # physically present — keep it, don't archive it.
            new_config[section] = dict(existing.items(section))
            continue
        new_orphans[section] = dict(existing.items(section))

    for section in orphans.sections():
        if section in current or new_config.has_section(section):
            continue
        if not new_orphans.has_section(section):
            new_orphans[section] = dict(orphans.items(section))

    config_header = (
        "# Auto-generated by `make hf-sync`. Sections are managed:\n"
        "#   - hf-sync owns the `model` line (rewritten every run).\n"
        "#   - All other keys are user-editable and preserved across runs.\n"
        "#   - Hand-added sections are kept as-is as long as their `model`\n"
        "#     file still exists in the symlink farm.\n"
        "#   - Removed GGUFs go to config.ini.orphans (restored if they return).\n"
    )
    if collisions:
        config_header += (
            "#\n"
            "# COLLISIONS — these basenames were shared by multiple HF repos;\n"
            "# every repo in the group got a qualified symlink name (see\n"
            "# sync-router.sh). Regenerated every hf-sync run.\n"
        )
        for basename, repos in collisions:
            config_header += f"#   {basename}: {repos}\n"
    config_header += "\n"

    orphan_header = (
        "# Orphan archive — sections for GGUFs no longer in the HF cache.\n"
        "# Restored verbatim if the GGUF returns. Edit freely.\n\n"
    )
    _write_atomic(new_config, config_path, config_header)
    _write_atomic(new_orphans, orphan_path, orphan_header)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
