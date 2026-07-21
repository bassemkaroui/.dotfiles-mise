#!/usr/bin/env python3
"""Print the `[dotfiles]` target keys declared in a mise config file.

Used by install.sh and mise/tasks/setup/custom-hookup to decide what to back up
BEFORE the companion repo's drop-in is applied for the first time.

Why this exists rather than `mise dotfiles status --json`: the status view of a
drop-in that was created moments earlier proved unreliable — in repeated
sandbox runs it omitted the new entries while the `dotfiles apply` immediately
afterwards honoured them. The entry that gets missed is the template-mode
`~/.ssh/config`, and template mode replaces a pre-existing real file with no
error and no backup (plan §2.26). Reading the file we just linked has no such
race.

With --with-source it prints `target<TAB>source` instead, which the caller uses
to fix up source permissions (git records no file modes, so a template
committed 0600 arrives from a clone at 0664 — and template mode gives the
rendered file the source's mode).

Exit codes are meaningful, because "this config declares nothing" and "I could
not read it" must not look alike to a caller that is about to overwrite files:

    0  targets printed (possibly none)
    3  no TOML parser available (Python < 3.11 without `tomli`)
    4  the file is missing or malformed
"""

import sys

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11 (Ubuntu 22.04)
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ModuleNotFoundError:
        print(
            "dotfiles-targets: needs Python 3.11+ (tomllib) or the `tomli` package",
            file=sys.stderr,
        )
        sys.exit(3)


def main() -> int:
    args = sys.argv[1:]
    with_source = "--with-source" in args
    args = [a for a in args if a != "--with-source"]
    if len(args) != 1:
        print(f"usage: {sys.argv[0]} [--with-source] <config.toml>", file=sys.stderr)
        return 4
    try:
        with open(args[0], "rb") as f:
            data = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"dotfiles-targets: cannot read {args[0]}: {e}", file=sys.stderr)
        return 4
    entries = data.get("dotfiles")
    if not isinstance(entries, dict):
        return 0
    for target, value in entries.items():
        if not with_source:
            print(target)
            continue
        # mise accepts both the dict form and the `target = "source"` shorthand.
        source = value.get("source") if isinstance(value, dict) else value
        print(f"{target}\t{source}" if isinstance(source, str) else f"{target}\t")
    return 0


if __name__ == "__main__":
    sys.exit(main())
