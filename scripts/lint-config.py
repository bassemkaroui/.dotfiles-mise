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
             conf.d/*.toml) *against* the repo's keys, so a drop-in can't
             silently collide with core. Also checks that [dotfiles] sources
             exist — a single missing source aborts every `mise dotfiles
             apply`. install.sh runs this pass because those files live outside
             the repo and CI never sees them.

Exit 0 when clean, 1 with a report when collisions or violations exist.
"""

import argparse
import glob
import os
import sys
import tomllib

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
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


def is_self_managed_key(key: str) -> bool:
    """Any [dotfiles] target that writes into mise's own config directory."""
    stripped = key.rstrip("/")
    return stripped == "~/.config/mise" or key.startswith("~/.config/mise/")


def check_self_managed(path: str, rel: str, data: dict, problems: list[str]) -> None:
    """D9a — only config.toml may manage ~/.config/mise/** targets."""
    for key in extract("dotfiles", data):
        if not is_self_managed_key(key):
            continue
        if os.path.basename(path) != SELF_MANAGED_OWNER or os.path.realpath(
            os.path.dirname(path)
        ) != os.path.realpath(MISE_DIR):
            problems.append(
                f"D9a: [dotfiles] {key!r} in {rel} — only the repo's {SELF_MANAGED_OWNER} may "
                f"manage ~/.config/mise/** targets"
            )
        elif key not in SELF_MANAGED_KEYS:
            problems.append(
                f"D9a: [dotfiles] {key!r} in {rel} is an unexpected ~/.config/mise/** "
                f"target (expected exactly {sorted(SELF_MANAGED_KEYS)})"
            )


def check_sources(rel: str, data: dict, problems: list[str]) -> None:
    """A [dotfiles] entry whose source is missing aborts the whole apply."""
    for key, value in extract("dotfiles", data).items():
        if not isinstance(value, dict):
            continue
        source = value.get("source")
        if not isinstance(source, str) or any(c in source for c in "*?["):
            continue  # globs are resolved by mise; nothing to stat here
        if not os.path.exists(os.path.expanduser(source)):
            problems.append(f"MISSING SOURCE: [dotfiles] {key!r} in {rel} -> {source}")


def check_repo_sources(rel: str, data: dict, problems: list[str]) -> None:
    """Every [dotfiles] entry must have a source that exists in this repo.

    Two different failure modes make this worth a lint rather than trusting
    mise to complain (both verified on 2026.7.7):

      - an entry with an EXPLICIT source that doesn't exist aborts the whole
        `dotfiles apply` — every other dotfile with it, not just that entry;
      - an entry with NO source (the mirrored `dotfiles.root` path) whose file
        is missing is silently dropped: it never deploys, never appears in
        `mise dotfiles status`, and `status --missing` still exits 0. A typo in
        a target path therefore produces a permanently unmanaged file with all
        checks green.

    Only repo-resolvable sources are checked. Sources pointing at paths a
    bootstrap step creates (a cloned repo, a machine-local file) can't be
    verified from a checkout — and belong in a task anyway, precisely because
    of the abort-the-whole-apply behaviour above.
    """
    root = os.path.join(REPO, "home")
    for key, value in extract("dotfiles", data).items():
        source = value.get("source") if isinstance(value, dict) else value
        if isinstance(source, str):
            if any(c in source for c in "*?["):
                continue  # glob: mise expands it, and zero matches is legal
            if source.startswith("~/.dotfiles-mise/"):
                path = os.path.join(REPO, source[len("~/.dotfiles-mise/") :])
            elif not os.path.isabs(source) and not source.startswith("~"):
                path = os.path.join(MISE_DIR, source)  # relative to the config file
            else:
                continue  # outside the repo — not knowable from a checkout
        else:
            # Sourceless entries mirror the home-relative target under
            # dotfiles.root. Targets outside $HOME must declare a source
            # (dotfiles.md), so there is nothing to resolve for them.
            if not key.startswith("~/"):
                continue
            path = os.path.join(root, key[len("~/") :])
        if not os.path.exists(path):
            problems.append(
                f"MISSING SOURCE: [dotfiles] {key!r} in {rel} -> {os.path.relpath(path, REPO)} "
                f"does not exist in the repo"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--live",
        action="store_true",
        help="lint machine-local config in ~/.config/mise against the repo's keys",
    )
    args = parser.parse_args()

    files = live_config_files() if args.live else repo_config_files()
    label = "live" if args.live else "repo"

    seen: dict[tuple[str, str], str] = {}
    problems: list[str] = []

    # In live mode the repo's keys are the baseline a drop-in must not collide
    # with, so load them first (without reporting collisions among themselves —
    # the default mode owns that).
    if args.live:
        for path in repo_config_files():
            rel = os.path.relpath(path, REPO)
            data = _load(path)
            for ns in NAMESPACES:
                for key in extract(ns, data):
                    seen.setdefault((ns, key), rel)

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

        # D9a applies in both modes — machine-local drop-ins are the least
        # reviewed files on the box, so they get the same check.
        check_self_managed(path, rel, data, problems)
        if args.live:
            check_sources(rel, data, problems)
        else:
            check_repo_sources(rel, data, problems)

    if not args.live:
        core = os.path.join(MISE_DIR, SELF_MANAGED_OWNER)
        core_data = _load(core)
        entries = extract("dotfiles", core_data)
        declared = {k for k in entries if is_self_managed_key(k)}
        # Don't pile "missing entry" noise on top of a parse error we already
        # reported for the same file.
        if core_data or not any(p.startswith("PARSE ERROR") for p in problems):
            for missing in SELF_MANAGED_KEYS - declared:
                problems.append(
                    f"D9a: {SELF_MANAGED_OWNER} is missing the self-management entry "
                    f"{missing!r} — without it the repo's config never links into "
                    f"~/.config/mise"
                )
        for key in declared:
            value = entries.get(key)
            source = value.get("source") if isinstance(value, dict) else value
            if not isinstance(source, str) or not source.startswith(("~/", "/")):
                problems.append(
                    f"D9a: [dotfiles] {key!r} needs an absolute source (~/... or /...); "
                    f"a relative one resolves against ~/.config/mise once linked, making "
                    f"the entry self-referential. Got: {source!r}"
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
