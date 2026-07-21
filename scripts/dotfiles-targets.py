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
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <config.toml>", file=sys.stderr)
        return 4
    try:
        with open(sys.argv[1], "rb") as f:
            data = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"dotfiles-targets: cannot read {sys.argv[1]}: {e}", file=sys.stderr)
        return 4
    entries = data.get("dotfiles")
    if not isinstance(entries, dict):
        return 0
    for target in entries:
        print(target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
