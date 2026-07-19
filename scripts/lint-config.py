#!/usr/bin/env python3
"""Collision lint for the mise config family (plan decision D9).

mise's precedence between sibling global config files (config.toml,
config.<env>.toml, config.local.toml, conf.d/*.toml) proved inconsistent on
2026.7.7 — same-key conflicts are resolved silently and order-dependently.
This repo therefore bans declaring the same key in two loadable files.

Checked namespaces (each key must appear in at most one file):
  - [dotfiles] target paths
  - [bootstrap.repos] target paths
  - [bootstrap.packages] entries
  - [tools] entries
  - [vars] keys
  - [tasks.*] names  (in particular: only mise/config.toml may define tasks
    that also exist elsewhere — any duplicate is an error)

Exit 0 when clean, 1 with a report when collisions exist.
"""

import glob
import os
import sys
import tomllib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MISE_DIR = os.path.join(REPO, "mise")


def config_files() -> list[str]:
    files = sorted(glob.glob(os.path.join(MISE_DIR, "config*.toml")))
    files += sorted(glob.glob(os.path.join(MISE_DIR, "conf.d", "*.toml")))
    # miserc.toml is not a mise.toml-family file (it only selects envs) — skip.
    return files


def extract(ns: str, data: dict) -> dict:
    cur = data
    for part in ns.split("."):
        cur = cur.get(part)
        if cur is None:
            return {}
    return cur if isinstance(cur, dict) else {}


NAMESPACES = ["dotfiles", "bootstrap.repos", "bootstrap.packages", "tools", "vars", "tasks"]


def main() -> int:
    seen: dict[tuple[str, str], str] = {}
    collisions: list[str] = []
    parse_errors: list[str] = []

    for path in config_files():
        rel = os.path.relpath(path, REPO)
        try:
            with open(path, "rb") as f:
                data = tomllib.load(f)
        except tomllib.TOMLDecodeError as e:
            parse_errors.append(f"{rel}: TOML parse error: {e}")
            continue
        for ns in NAMESPACES:
            for key in extract(ns, data):
                ident = (ns, key)
                if ident in seen:
                    collisions.append(
                        f"[{ns}] {key!r} declared in both {seen[ident]} and {rel}"
                    )
                else:
                    seen[ident] = rel

    for err in parse_errors:
        print(f"PARSE ERROR: {err}")
    for c in collisions:
        print(f"COLLISION: {c}")
    if parse_errors or collisions:
        return 1
    print(f"lint-config: OK ({len(seen)} keys across {len(config_files())} files, no collisions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
