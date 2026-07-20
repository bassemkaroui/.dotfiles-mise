#!/usr/bin/env python3
"""Collision lint for the mise config family (plan decisions D9/D9a).

mise's precedence between sibling config files (config.toml, config.<env>.toml,
config.local.toml, conf.d/*.toml) proved inconsistent on 2026.7.7 — same-key
conflicts are resolved silently and order-dependently. This repo therefore bans
declaring the same key in two loadable files.

Checked namespaces (each key must appear in at most one file):
  - [dotfiles] target paths
  - [bootstrap.repos] target paths
  - [bootstrap.packages] entries
  - [tools] entries
  - [vars] keys
  - [tasks.*] names

Also enforced (D9a): mise's own config is self-managed by exactly two entries in
config.toml; no other file may declare a ~/.config/mise/** dotfiles target.

Modes:
  (default)  lint the repo's tracked config files
  --live     lint the machine-local config in ~/.config/mise (config*.toml and
             conf.d/*.toml). A single broken drop-in there aborts every
             `mise dotfiles apply`, and those files are outside the repo, so
             install.sh runs this pass too.

Exit 0 when clean, 1 with a report when collisions or violations exist.
"""

import argparse
import glob
import os
import sys
import tomllib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MISE_DIR = os.path.join(REPO, "mise")

NAMESPACES = ["dotfiles", "bootstrap.repos", "bootstrap.packages", "tools", "vars", "tasks"]

# D9a: the only permitted self-management entries, and their only permitted home.
SELF_MANAGED_KEYS = {
    "~/.config/mise/config*.toml",
    "~/.config/mise/tasks",
}
SELF_MANAGED_OWNER = "config.toml"


def repo_config_files() -> list[str]:
    # miserc.toml only selects environments; it is not a mise.toml-family file.
    return sorted(glob.glob(os.path.join(MISE_DIR, "config*.toml")))


def live_config_files() -> list[str]:
    conf_dir = os.environ.get("MISE_CONFIG_DIR") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "mise"
    )
    files = sorted(glob.glob(os.path.join(conf_dir, "config*.toml")))
    files += sorted(glob.glob(os.path.join(conf_dir, "conf.d", "*.toml")))
    # Skip links back into the repo — those are linted by the default mode.
    return [f for f in files if not os.path.realpath(f).startswith(REPO + os.sep)]


def extract(ns: str, data: dict) -> dict:
    cur = data
    for part in ns.split("."):
        cur = cur.get(part)
        if cur is None:
            return {}
    return cur if isinstance(cur, dict) else {}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--live",
        action="store_true",
        help="lint machine-local config in ~/.config/mise instead of the repo",
    )
    args = parser.parse_args()

    files = live_config_files() if args.live else repo_config_files()
    label = "live" if args.live else "repo"

    seen: dict[tuple[str, str], str] = {}
    problems: list[str] = []

    for path in files:
        rel = os.path.relpath(path, REPO) if not args.live else path
        try:
            with open(path, "rb") as f:
                data = tomllib.load(f)
        except tomllib.TOMLDecodeError as e:
            problems.append(f"PARSE ERROR: {rel}: {e}")
            continue
        except OSError as e:
            problems.append(f"READ ERROR: {rel}: {e}")
            continue

        for ns in NAMESPACES:
            for key in extract(ns, data):
                ident = (ns, key)
                if ident in seen:
                    problems.append(
                        f"COLLISION: [{ns}] {key!r} declared in both {seen[ident]} and {rel}"
                    )
                else:
                    seen[ident] = rel

        # D9a — self-management entries are config.toml's alone.
        if not args.live:
            for key in extract("dotfiles", data):
                if not key.startswith("~/.config/mise/"):
                    continue
                if os.path.basename(path) != SELF_MANAGED_OWNER:
                    problems.append(
                        f"D9a: [dotfiles] {key!r} in {rel} — only {SELF_MANAGED_OWNER} may "
                        f"manage ~/.config/mise/** targets"
                    )
                elif key not in SELF_MANAGED_KEYS:
                    problems.append(
                        f"D9a: [dotfiles] {key!r} in {rel} is an unexpected ~/.config/mise/** "
                        f"target (expected exactly {sorted(SELF_MANAGED_KEYS)})"
                    )

    if not args.live:
        declared = {
            k
            for path in files
            if os.path.basename(path) == SELF_MANAGED_OWNER
            for k in extract("dotfiles", _load(path))
            if k.startswith("~/.config/mise/")
        }
        for missing in SELF_MANAGED_KEYS - declared:
            problems.append(
                f"D9a: config.toml is missing the self-management entry {missing!r} — "
                f"without it the repo's config never links into ~/.config/mise"
            )

    for p in problems:
        print(p)
    if problems:
        return 1
    print(f"lint-config ({label}): OK ({len(seen)} keys across {len(files)} files, no collisions)")
    return 0


def _load(path: str) -> dict:
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except (tomllib.TOMLDecodeError, OSError):
        return {}


if __name__ == "__main__":
    sys.exit(main())
