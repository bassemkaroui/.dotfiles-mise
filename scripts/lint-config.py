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
import re
import sys

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11 (Ubuntu 22.04 ships 3.10)
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ModuleNotFoundError:
        # Exit 2, not 1: "I could not lint" is not "the config is broken", and
        # install.sh must not refuse to install a machine over a missing stdlib
        # module. It degrades to a warning on 2 and still aborts on 1.
        print(
            "lint-config: needs Python 3.11+ (tomllib) or the `tomli` package "
            "(apt install python3-tomli) — cannot lint",
            file=sys.stderr,
        )
        sys.exit(2)

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
MISE_DIR = os.path.join(REPO, "mise")

NAMESPACES = [
    "dotfiles",
    "bootstrap.repos",
    "bootstrap.packages",
    # A profile file (or a companion drop-in) redeclaring a hook silently
    # REPLACES it by undefined precedence rather than adding to it. The one in
    # config.toml creates ~/.gnupg and ~/.ssh at 0700 before the dotfiles step;
    # losing it means gpg refuses its homedir and ssh refuses its config (§2.17)
    # — with no error from mise at any point.
    "bootstrap.hooks",
    "tools",
    "vars",
    "env",
    "alias",
    "tasks",
]

# mise ignores an unknown mode "with a warning" (dotfiles.md) — the entry is
# then simply not managed, `dotfiles status --missing` still exits 0, and the
# file never deploys. A typo in a mode is therefore invisible to every other
# check in this repo.
VALID_MODES = {"symlink", "symlink-each", "copy", "template"}


def flatten_settings(data: dict, prefix: str = "") -> dict:
    """[settings] as dotted leaf keys, for the one-key-one-file rule.

    Every setting is a singleton, not just dotfiles.root: two files declaring
    the same one are resolved by mise's inconsistent sibling precedence (§2.2)
    and the loser is silent. dotfiles.root is merely the most destructive case
    — the loser's sourceless entries resolve under the winner's root and are
    reported as "source missing", which aborts every apply.
    """
    settings = data.get("settings") if not prefix else data
    if not isinstance(settings, dict):
        return {}
    flat: dict = {}
    for key, value in settings.items():
        dotted = f"{prefix}{key}"
        if isinstance(value, dict):
            flat.update(flatten_settings(value, prefix=f"{dotted}."))
        else:
            flat[dotted] = value
    return flat

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


def entry_source(value: object) -> object:
    """The declared source, or a non-str for a sourceless (mirrored) entry.

    mise accepts both `target = "source"` and the dict form; the shorthand was
    once silently skipped here, so a companion repo using it got a green lint
    and an apply that aborts for the WHOLE machine.
    """
    return value.get("source") if isinstance(value, dict) else value


def is_absolute_source(source: str) -> bool:
    return os.path.isabs(source) or source.startswith("~")


def check_relative_sources(rel: str, data: dict, problems: list[str]) -> None:
    """No entry in this config family may use a relative source.

    dotfiles.md: "Relative explicit sources resolve against the directory of
    the config file that declares the entry." Every file in this family is
    loaded from ~/.config/mise (config*.toml, linked there by the D9a
    self-management entries) or from ~/.config/mise/conf.d (a companion
    drop-in) — never from the repo — so a relative source silently points at
    mise's own config directory instead of at the repo.

    This lint used to *resolve* relative sources against the repo and pronounce
    them fine, which is the one answer that is wrong in both modes. Verified:
    `"~/.myrc" = { source = "miserc.example.toml" }` in mise/config.toml linted
    OK and deployed as `~/.myrc -> ~/.config/mise/miserc.example.toml  source
    missing` — and per §2.16 a missing explicit source aborts the ENTIRE apply,
    every other dotfile with it.
    """
    for key, value in extract("dotfiles", data).items():
        source = entry_source(value)
        if not isinstance(source, str) or is_absolute_source(source):
            continue
        problems.append(
            f"RELATIVE SOURCE: [dotfiles] {key!r} in {rel} -> {source!r} resolves against "
            f"the declaring config file's directory (~/.config/mise), not the repo. "
            f"Use an absolute source (~/.dotfiles-mise/... or ~/<companion>/...)."
        )


def check_modes(rel: str, data: dict, problems: list[str]) -> None:
    """An unknown mode is ignored WITH A WARNING and the entry never deploys.

    dotfiles.md: "Unknown modes and operations are ignored with a warning".
    Verified with `mode = "symlink-eachh"`: mise warns once, the target is
    never created, and `mise dotfiles status --missing` still exits 0 — so
    nothing else in this repo would notice.
    """
    for key, value in extract("dotfiles", data).items():
        if not isinstance(value, dict):
            continue  # string shorthand takes dotfiles.default_mode
        mode = value.get("mode")
        if mode is None or mode in VALID_MODES:
            continue
        problems.append(
            f"UNKNOWN MODE: [dotfiles] {key!r} in {rel} has mode={mode!r} — mise ignores the "
            f"entry with a warning and it never deploys. Expected one of {sorted(VALID_MODES)}"
        )
    default_mode = flatten_settings(data).get("dotfiles.default_mode")
    if default_mode is not None and default_mode not in VALID_MODES:
        problems.append(
            f"UNKNOWN MODE: [settings] dotfiles.default_mode={default_mode!r} in {rel} — "
            f"expected one of {sorted(VALID_MODES)}"
        )


def check_sources(rel: str, data: dict, problems: list[str]) -> None:
    """A [dotfiles] entry whose source is missing aborts the whole apply.

    Live mode only. Sources are absolute by then (check_relative_sources owns
    the rest), so expanduser is enough and — unlike the previous version — the
    verdict no longer depends on the caller's cwd. It did: the same drop-in
    passed from `repo/mise` and failed from `/`, while install.sh calls this
    from wherever the user happened to be standing.
    """
    for key, value in extract("dotfiles", data).items():
        source = entry_source(value)
        if not isinstance(source, str) or not is_absolute_source(source):
            continue
        if any(c in source for c in "*?["):
            continue  # globs are resolved by mise; nothing to stat here
        if not os.path.exists(os.path.expanduser(source)):
            problems.append(f"MISSING SOURCE: [dotfiles] {key!r} in {rel} -> {source}")


def dotfiles_root() -> str:
    """`dotfiles.root` as declared in the repo's config.toml (not hardcoded).

    Sourceless entries mirror their home-relative target under it, so the lint
    below has to resolve against the same value mise will use.
    """
    settings = _load(os.path.join(MISE_DIR, SELF_MANAGED_OWNER)).get("settings", {})
    root = settings.get("dotfiles", {}).get("root") if isinstance(settings, dict) else None
    if not isinstance(root, str):
        return os.path.join(REPO, "home")
    if root.startswith("~/.dotfiles-mise/"):
        return os.path.join(REPO, root[len("~/.dotfiles-mise/") :])
    return os.path.expanduser(root)


def check_repo_sources(rel: str, data: dict, problems: list[str], live: bool = False) -> None:
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
    root = dotfiles_root()
    for key, value in extract("dotfiles", data).items():
        source = entry_source(value)
        if isinstance(source, str):
            if not is_absolute_source(source):
                continue  # relative: check_relative_sources owns it
            if source.startswith("~/.dotfiles-mise/"):
                path = os.path.join(REPO, source[len("~/.dotfiles-mise/") :])
                if any(c in source for c in "*?["):
                    continue  # glob: mise expands it, and zero matches is legal
            else:
                # Previously `continue  # not knowable from a checkout`, which
                # let a source pointing anywhere outside the repo pass every
                # check this repo has. Verified: `source =
                # "/opt/definitely-not-here/somerc"` in config.graphical.toml
                # linted OK, passed both sandbox arms and `dotfiles status`
                # rc=0, and only failed on a real apply — where, per §2.16, it
                # takes every other dotfile down with it.
                #
                # It is also a design rule (README): no source may point at
                # something a bootstrap step creates. A path outside the repo
                # cannot be verified from a checkout, so it belongs in a task
                # (see setup:repo-links), not in [dotfiles]. The companion
                # repo's own sources are exempt — they live in live-mode files,
                # which check_sources stats on the real machine.
                if live:
                    continue
                problems.append(
                    f"OUT-OF-REPO SOURCE: [dotfiles] {key!r} in {rel} -> {source} cannot be "
                    f"verified from a checkout. A missing explicit source aborts the entire "
                    f"apply; link it from a task instead (cf. setup:repo-links)."
                )
                continue
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


def check_profile_registry(problems: list[str]) -> None:
    """install.sh's KNOWN_PROFILES must list every config.<profile>.toml.

    install.sh validates DOTFILES_PROFILES against a hand-maintained array and
    *warns and drops* anything it does not recognise. Add a profile file
    without touching that array and `DOTFILES_PROFILES=<new>` silently seeds a
    machine without it: the install still succeeds, the warning scrolls past,
    and the profile is simply never active.

    Only this direction is checked. The reverse is legitimate: `laptop`,
    `desktop` and `veracrypt` are device/opt-in markers consumed by tasks and
    template-mode entries, and have no config file of their own by design.
    """
    install_sh = os.path.join(REPO, "install.sh")
    try:
        with open(install_sh, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        problems.append(f"install.sh unreadable, cannot check KNOWN_PROFILES: {e}")
        return
    match = re.search(r"^KNOWN_PROFILES=\(([^)]*)\)", text, re.MULTILINE)
    if not match:
        problems.append(
            "install.sh no longer defines KNOWN_PROFILES=( ... ) — the profile registry "
            "check cannot run; update scripts/lint-config.py to match"
        )
        return
    known = set(match.group(1).split())
    for path in repo_config_files():
        base = os.path.basename(path)
        if base == SELF_MANAGED_OWNER:
            continue
        name = base[len("config.") : -len(".toml")]
        if name not in known:
            problems.append(
                f"PROFILE REGISTRY: mise/{base} exists but {name!r} is not in install.sh's "
                f"KNOWN_PROFILES, so DOTFILES_PROFILES={name} would be warned about and dropped"
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
            # Settings too, or a drop-in redeclaring dotfiles.root (or
            # activate_aggressive, or anything else) would look collision-free
            # against the repo baseline.
            for setting in flatten_settings(data):
                seen.setdefault(("settings", setting), rel)

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

        for setting in flatten_settings(data):
            ident = ("settings", setting)
            if ident in seen:
                problems.append(
                    f"COLLISION: [settings] {setting!r} declared in both {seen[ident]} "
                    f"and {rel} — precedence between sibling configs is undefined"
                )
            else:
                seen[ident] = rel

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
        # Both modes: a relative source and an unknown mode are wrong wherever
        # they are declared, and neither produces an error from mise.
        check_relative_sources(rel, data, problems)
        check_modes(rel, data, problems)
        # check_repo_sources covers sourceless entries (silently dropped by
        # mise) and in-repo ones; check_sources covers absolute/machine paths,
        # which only exist — and can only be stat'ed — on a real machine.
        check_repo_sources(rel, data, problems, live=args.live)
        if args.live:
            check_sources(rel, data, problems)

    if not args.live:
        check_profile_registry(problems)
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
