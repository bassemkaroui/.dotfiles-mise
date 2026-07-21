#!/usr/bin/env python3
"""Freshness check for every `[bootstrap.repos]` entry declared in this repo.

The successor to the old repo's monthly submodule-freshness workflow. The old
repo pinned oh-my-tmux and the nvim config as git submodules, so "freshness"
meant bumping a committed pointer. Here they are plain clones at live paths
that track their default branch, and `mise run update:repos` moves them on the
machine — there is no pointer in this repo to bump.

What *can* still rot here, and what this checks instead:

  1. **An upstream that moved or died.** A `[bootstrap.repos]` clone that fails
     aborts the ENTIRE bootstrap at step 2 — no dotfiles, no tools, no
     imperative tail (plan §2.28, verified). A repo that gets renamed, made
     private or deleted therefore bricks every fresh install, silently, until
     someone tries one. PathPicker is archived upstream today; that class of
     entry is exactly the risk.
  2. **A `ref` that no longer exists** on the remote — same blast radius, and
     invisible on machines that already cloned it.

Both are answered by `git ls-remote`, which needs no clone and no credentials
for a public repo. Run monthly in CI; exits non-zero with a report so the
workflow can open an issue.

Usage: scripts/check-repos.py [--timeout SECONDS]
"""

import argparse
import glob
import os
import subprocess
import sys
import tomllib

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
MISE_DIR = os.path.join(REPO, "mise")


def declared_repos() -> list[tuple[str, str, str | None]]:
    """(config file, url, ref) for every [bootstrap.repos] entry in the repo."""
    out = []
    for path in sorted(glob.glob(os.path.join(MISE_DIR, "config*.toml"))):
        with open(path, "rb") as f:
            data = tomllib.load(f)
        entries = data.get("bootstrap", {}).get("repos", {})
        for target, value in entries.items():
            if isinstance(value, str):
                url, ref = value, None
            elif isinstance(value, dict):
                url, ref = value.get("url"), value.get("ref")
            else:
                continue
            if url:
                out.append((f"{os.path.basename(path)}:{target}", url, ref))
    return out


def ls_remote(url: str, timeout: int) -> tuple[bool, str]:
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="/bin/true")
    try:
        proc = subprocess.run(
            ["git", "ls-remote", "--heads", "--tags", url],
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired:
        return False, f"timed out after {timeout}s"
    if proc.returncode != 0:
        return False, (proc.stderr.strip().splitlines() or ["unknown error"])[-1]
    return True, proc.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()

    problems: list[str] = []
    entries = declared_repos()
    if not entries:
        # NOT `return 0`. This runs monthly and unattended, so "I parsed
        # nothing" and "there is nothing to check" must not look alike: rename
        # mise/, restructure the configs, or lose the entries, and the workflow
        # reports green forever while checking no repository at all. Verified
        # against a skeleton with an empty mise/: it exited 0.
        configs = sorted(glob.glob(os.path.join(MISE_DIR, "config*.toml")))
        print(
            f"No [bootstrap.repos] entries found in {len(configs)} config file(s) "
            f"under {MISE_DIR}.\n"
            "This repo declares several, so this almost certainly means the config "
            "layout moved and this script no longer knows where to look.",
            file=sys.stderr,
        )
        return 1

    for where, url, ref in entries:
        okay, payload = ls_remote(url, args.timeout)
        if not okay:
            problems.append(
                f"UNREACHABLE: {where}\n"
                f"    url: {url}\n"
                f"    git ls-remote said: {payload}\n"
                f"    A failing clone aborts the whole bootstrap — every fresh install breaks."
            )
            continue
        if ref:
            refs = {line.split("\t", 1)[1] for line in payload.splitlines() if "\t" in line}
            shas = {line.split("\t", 1)[0] for line in payload.splitlines() if "\t" in line}
            found = (
                f"refs/heads/{ref}" in refs
                or f"refs/tags/{ref}" in refs
                or f"refs/tags/{ref}^{{}}" in refs
                or any(sha.startswith(ref) for sha in shas)
                # A full SHA can point at an unadvertised commit; ls-remote
                # cannot disprove it, so a 40-char hex ref is left alone.
                or (len(ref) == 40 and all(c in "0123456789abcdef" for c in ref.lower()))
            )
            if not found:
                problems.append(
                    f"MISSING REF: {where}\n"
                    f"    url: {url}\n"
                    f"    ref '{ref}' is neither a branch nor a tag on the remote."
                )
                continue
        print(f"ok  {where}  ({url}{f' @ {ref}' if ref else ''})")

    if problems:
        print()
        print(f"{len(problems)} problem(s):")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"\nAll {len(entries)} declared repos reachable.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
