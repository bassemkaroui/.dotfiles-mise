#!/usr/bin/env bash
# Bootstrap entry point — the only imperative step that runs before mise owns
# the machine. Everything here must stay idempotent.
#
#   git clone https://github.com/bassemkaroui/.dotfiles-mise.git ~/.dotfiles-mise
#   ~/.dotfiles-mise/install.sh
#
# Also the supported upgrade path for machines running an older layout — it
# converts ~/.config/mise, fixes up trust, and backs up conflicting files, none
# of which a bare `mise bootstrap` would do.
#
# Env:
#   DOTFILES_PROFILES=graphical,ai,dev   seed ~/.config/mise/miserc.toml non-interactively
#   DOTFILES_NONINTERACTIVE=1            never prompt; safe defaults
#   MISE_GITHUB_TOKEN / GITHUB_TOKEN / GH_TOKEN   GitHub API token (see step 2)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NONINTERACTIVE="${DOTFILES_NONINTERACTIVE:-0}"
# No usable stdin (curl | bash, CI) == non-interactive: `read` would EOF-exit
# the script mid-prompt under set -e.
[[ -t 0 ]] || NONINTERACTIVE=1

KNOWN_PROFILES=(graphical gnome cosmic ai dev yazi neovim media veracrypt laptop desktop)

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
die() {
    printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2
    exit 1
}

# ── 0. Layout assumptions the config hardcodes ────────────────────────────────
# mise/config.toml's self-management entries name ~/.dotfiles-mise and
# ~/.config/mise literally. Fail loudly here rather than let mise degrade a
# non-matching source glob into a warning and "succeed" with nothing linked.
[[ "$(readlink -f "$REPO")" == "$(readlink -f "$HOME/.dotfiles-mise")" ]] \
    || die "This repo must live at ~/.dotfiles-mise (found: $REPO).
      The [dotfiles] entries in mise/config.toml hardcode that path.
      Move the clone, or edit those entries and dotfiles.root to match."
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/mise"
[[ "$CONF" == "$HOME/.config/mise" ]] \
    || die "XDG_CONFIG_HOME points mise config at $CONF, but mise/config.toml
      targets ~/.config/mise literally. Unset XDG_CONFIG_HOME or edit those entries."

# ── 1. mise itself ────────────────────────────────────────────────────────────
if ! command -v mise &>/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    info "Installing mise..."
    curl -fsSL https://mise.run | sh
fi
export PATH="$HOME/.local/bin:$PATH"

# ── 1b. Work around libcurl-gnutls + HTTP/2 before any cloning ────────────────
# `[bootstrap.repos]` clones at bootstrap step 2, using whatever git is on PATH
# — on a fresh machine that is apt's git, which Debian/Ubuntu link against
# libcurl-gnutls. That combination drops large packs mid-transfer on some
# networks: `RPC failed; curl 56 GnuTLS recv error (-24)`, `early EOF`,
# `fetch-pack: invalid index-pack output`. A failing clone aborts the ENTIRE
# bootstrap (§2.28), so a fresh install dies at step 2 with nothing deployed.
#
# Measured on the author's network (2026-07-21), cloning oh-my-zsh:
#   /usr/bin/git (libcurl-gnutls), HTTP/2 default → fails
#   /usr/bin/git (libcurl-gnutls), http.version=HTTP/1.1 → 26 MB, clean
#   conda git (OpenSSL libcurl), HTTP/2 default → 26 MB, clean
# which is the same libcurl-gnutls trouble that made `conda:git` a core tool in
# the first place — except that tool is installed at step 9, seven steps too
# late to help the clones.
#
# GIT_CONFIG_COUNT rather than a config file: mise runs git as a child process,
# so the environment reaches it, and nothing has to be written into ~/.gitconfig
# — which at this point is neither deployed nor safe to create (it is a managed
# symlink target, and a real file there would collide with its [dotfiles] entry).
if git_https_helper="$(git --exec-path 2>/dev/null)/git-remote-https" \
    && ldd "$git_https_helper" 2>/dev/null | grep -q 'libcurl-gnutls'; then
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1
    info "git is linked against libcurl-gnutls — forcing HTTP/1.1 for clones"
    info "(HTTP/2 + gnutls truncates large packs on some networks; see install.sh)"
fi

# ── 2. GitHub token ───────────────────────────────────────────────────────────
# Installing [tools] resolves aqua/github-backed tools through the GitHub
# releases API (60 req/hr unauthenticated, and throttled/slow when anonymous). A
# token lifts the cap AND makes responses fast, so it is worth getting one before
# `mise bootstrap`. It must be exported HERE, in the parent process — hooks and
# tasks run too late. mise reads it from GITHUB_TOKEN / MISE_GITHUB_TOKEN (and
# from a gh login).
#
# Raise the version-list timeout for the real bootstrap — a slow uplink can
# exceed the 20s default. This does NOT affect mise's "fast commands" (hook-env,
# activate, exec, env, ls, current, where, which, shims), which mise HARD-CAPS at
# 3s "so shims and shell activation do not block". That cap is the whole reason
# an earlier `mise exec gh@latest` probe timed out at 3.00s — so gh is installed
# below with `mise install` (NOT a fast command → full timeout), after which
# `mise exec gh@latest -- gh` runs from the local install without touching the API.
export MISE_FETCH_REMOTE_VERSIONS_TIMEOUT="${MISE_FETCH_REMOTE_VERSIONS_TIMEOUT:-60s}"

# Run gh whether it is already on PATH or only mise-installed. Once gh is
# installed, `mise exec gh@latest -- gh` resolves it from the local install, so
# this is NOT subject to the 3s fast-command cap (verified).
gh_run() {
    mkdir -p "${GH_CONFIG_DIR:-$HOME/.config/gh}" 2>/dev/null || true # gh errors without it
    if command -v gh &>/dev/null; then
        gh "$@"
    else
        mise exec gh@latest -- gh "$@"
    fi
}

if [[ -z "${MISE_GITHUB_TOKEN:-}" ]]; then
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        export MISE_GITHUB_TOKEN="$GITHUB_TOKEN"
        ok "GitHub token loaded from \$GITHUB_TOKEN"
    elif [[ -n "${GH_TOKEN:-}" ]]; then
        export MISE_GITHUB_TOKEN="$GH_TOKEN"
        ok "GitHub token loaded from \$GH_TOKEN"
    elif command -v gh &>/dev/null && gh auth token &>/dev/null; then
        MISE_GITHUB_TOKEN="$(gh auth token)"
        export MISE_GITHUB_TOKEN
        ok "GitHub token loaded from gh CLI"
    elif [[ "$NONINTERACTIVE" == "1" ]]; then
        # No terminal for a device-code login (CI, curl | bash). gh still gets
        # installed later as a [tools] entry; this run just goes unauthenticated.
        warn "No GitHub token found — installing tools against the unauthenticated"
        warn "API (60 req/hr). Set GITHUB_TOKEN (a no-scope PAT) and re-run if limited."
    else
        warn "No GitHub token found. A token lifts the 60 req/hr cap and speeds"
        warn "up tool installs. gh can fetch one via a browser device-code login."
        read -rp "Authenticate with GitHub via gh now? [Y/n] " a || a=n
        if [[ ! "$a" =~ ^[Nn]$ ]]; then
            # Make sure gh is present. It is a managed [tools] entry, so the
            # bootstrap installs it regardless — but to authenticate BEFORE
            # bootstrap we install it now, with `mise install` (NOT `mise exec`:
            # exec is a 3s-capped fast command, which is what failed before;
            # install uses the full timeout above). Non-fatal throughout: a
            # failed install or login just leaves the run unauthenticated.
            gh_ready=true
            if ! command -v gh &>/dev/null; then
                info "Installing gh to authenticate (one-off; it is a managed tool anyway)..."
                mise install gh@latest || {
                    gh_ready=false
                    warn "Could not install gh — is the GitHub API reachable from here?"
                }
            fi
            if [[ "$gh_ready" == true ]]; then
                gh_token=""
                if gh_run auth login && gh_token="$(gh_run auth token 2>/dev/null)" \
                    && [[ -n "$gh_token" ]]; then
                    export MISE_GITHUB_TOKEN="$gh_token"
                    ok "GitHub token obtained via gh"
                else
                    warn "gh login did not complete."
                fi
            fi
        fi
        if [[ -z "${MISE_GITHUB_TOKEN:-}" ]]; then
            warn "Continuing without a token (best effort). If a tool install is"
            warn "rate-limited, re-run with GITHUB_TOKEN=ghp_... exported (no scopes)."
        fi
    fi
else
    ok "GitHub token already set (\$MISE_GITHUB_TOKEN)"
fi

# ── 3. Prepare ~/.config/mise as a REAL directory ─────────────────────────────
# mise's own config is self-managed: mise/config.toml declares [dotfiles]
# entries that link config*.toml and tasks/ into ~/.config/mise. That directory
# must stay real so machine-local state (miserc.toml, conf.d/ drop-ins) lives
# outside the repo. Two legacy shapes need converting first.
mkdir -p "$(dirname "$CONF")"

# Rescue machine-local files that older layouts kept (gitignored) inside the
# repo. Runs before anything is removed, so an interrupted conversion never
# strands them — and it accepts any clone, not just the one we're installing.
rescue_machine_local() {
    local src="$1" f
    [[ -d "$src" ]] || return 0
    mkdir -p "$CONF"
    shopt -s nullglob
    for f in "$src/miserc.toml" "$src"/config*.local.toml; do
        [[ -f "$f" && ! -e "$CONF/$(basename "$f")" ]] || continue
        mv "$f" "$CONF/" && ok "Rescued machine-local $(basename "$f") out of $src"
    done
    if [[ -d "$src/conf.d" ]]; then
        mkdir -p "$CONF/conf.d"
        for f in "$src"/conf.d/*; do
            [[ -f "$f" && ! -e "$CONF/conf.d/$(basename "$f")" ]] || continue
            mv "$f" "$CONF/conf.d/" && ok "Rescued machine-local conf.d/$(basename "$f") out of $src"
        done
        rmdir "$src/conf.d" 2>/dev/null \
            || warn "$src/conf.d still has files — left in place, move them to $CONF/conf.d/ by hand"
    fi
    shopt -u nullglob
}

# Is $1 the mise/ directory of a clone of THIS repo (not necessarily $REPO)?
#
# "config.toml + tasks/" alone is NOT enough: the OLD repo's stow package
# (~/.dotfiles/mise/tag-default/.config/mise) has exactly that shape, plus the
# conf.d/*.toml files it tracks in git. Treating it as a legacy layout would
# delete its ~/.config/mise deployment and *move its tracked conf.d files out of
# its working tree* — mutating the rollback path before the old-repo guard
# further down ever gets a chance to run. The sibling install.sh + home/ are
# what actually identify this repo.
is_this_repo_mise_dir() {
    [[ -f "$1/config.toml" && -d "$1/tasks" && -f "$1/../install.sh" && -d "$1/../home" ]]
}

OLD_REPO="${DOTFILES_OLD_REPO:-$HOME/.dotfiles}"
# The private companion repo is deployed by the SAME stow run and is just as
# much part of the rollback path: ~/.gitconfig, ~/.ssh/config, ~/.p10k.zsh and
# ~/.local/share/gnome-extensions are symlinks into it on a machine that hasn't
# cut over. Now that this repo declares ~/.gitconfig and friends, applying
# without this check would rewrite files inside it.
OLD_CUSTOM_REPO="${DOTFILES_OLD_CUSTOM_REPO:-$HOME/.dotfiles-custom}"

LEGACY_SRC=""
if [[ -L "$CONF" ]]; then
    LINK_TARGET="$(readlink -f "$CONF" || true)"
    # Bail out before touching anything if ~/.config/mise is the OLD repo's
    # stow deployment. The full guard below needs mise to enumerate targets;
    # this one case has to be caught earlier, because step 3 mutates the
    # filesystem before that guard runs.
    if [[ -d "$OLD_REPO" && -n "$LINK_TARGET" && "$LINK_TARGET" == "$(readlink -f "$OLD_REPO")"/* ]]; then
        # shellcheck disable=SC2088  # tilde is literal display text, not a path to expand
        die "~/.config/mise is still the OLD repo's stow deployment ($LINK_TARGET).
      Unstow it first (MIGRATION.md step 3), then re-run this script."
    fi
    if [[ -n "$LINK_TARGET" ]] && is_this_repo_mise_dir "$LINK_TARGET"; then
        info "Converting legacy ~/.config/mise dir symlink into a real directory"
        # Drop the symlink first: while it stands, $CONF resolves *into* the
        # clone, so "move out of the repo" would be a no-op onto itself.
        rm "$CONF"
        LEGACY_SRC="$LINK_TARGET"
    else
        BAK="$CONF.bak.$(date +%Y%m%d%H%M%S)"
        # shellcheck disable=SC2088  # tilde is literal display text, not a path to expand
        warn "~/.config/mise is a symlink elsewhere ($LINK_TARGET) — backing up to $BAK"
        mv "$CONF" "$BAK"
    fi
fi
mkdir -p "$CONF"
[[ -n "$LEGACY_SRC" ]] && rescue_machine_local "$LEGACY_SRC"
# Also rescue from this repo, covering a run interrupted mid-conversion and
# clones whose machine-local files were committed to the old layout.
rescue_machine_local "$REPO/mise"

# A pre-existing real global config would (a) make the first dotfiles apply
# refuse the conflict and (b) error as untrusted once MISE_GLOBAL_CONFIG_FILE
# points at the repo. Move aside only the files this repo is about to link —
# machine-local *.local.toml overrides are never ours to touch.
shopt -s nullglob
for f in "$CONF"/config*.toml; do
    base="$(basename "$f")"
    [[ -f "$f" && ! -L "$f" ]] || continue
    [[ "$base" == *.local.toml ]] && continue
    [[ -e "$REPO/mise/$base" ]] || continue
    bak="$f.pre-mise.bak"
    n=1
    while [[ -e "$bak" ]]; do bak="$f.pre-mise.bak$((n++))"; done
    warn "Backing up pre-existing $base -> $(basename "$bak")"
    mv "$f" "$bak"
done
shopt -u nullglob

# ── 4. Per-machine profile selection (miserc.toml, machine-local) ─────────────
MISERC="$CONF/miserc.toml"
if [[ -f "$MISERC" ]]; then
    # shellcheck disable=SC2088  # tilde is literal display text in a message, not a path
    ok "~/.config/mise/miserc.toml already present: $(grep -E '^env' "$MISERC" || echo '(no env line)')"
else
    PROFILES="${DOTFILES_PROFILES:-}"
    if [[ -z "$PROFILES" && "$NONINTERACTIVE" != "1" ]]; then
        echo "Available profiles: ${KNOWN_PROFILES[*]}"
        read -rp "Profiles for this machine (comma/space-separated, empty = core only): " PROFILES || PROFILES=""
    fi
    selected=()
    # split on commas and/or whitespace
    for p in ${PROFILES//,/ }; do
        if [[ " ${KNOWN_PROFILES[*]} " == *" $p "* ]]; then
            selected+=("$p")
        else
            warn "Unknown profile '$p' — skipping (no config.$p.toml exists; mise would silently ignore it)"
        fi
    done
    {
        echo "# Per-machine profile selection — see miserc.example.toml"
        if [[ ${#selected[@]} -gt 0 ]]; then
            printf 'env = ['
            for i in "${!selected[@]}"; do
                [[ $i -eq 0 ]] || printf ', '
                printf '"%s"' "${selected[$i]}"
            done
            printf ']\n'
        else
            echo 'env = []'
        fi
    } >"$MISERC"
    ok "Wrote ~/.config/mise/miserc.toml (profiles: ${selected[*]:-none})"
fi

# ── 4a. python3 is a hard requirement ─────────────────────────────────────────
# Not a nicety: three safety nets are written in it — the old-repo guard, the
# conflict backup (the only thing standing between a template-mode entry and a
# real ~/.ssh/config, §2.26) and the collision lint. Skipping them silently on a
# host without python3 is how a "successful" install eats a file. Every
# Debian-family system this repo targets ships it.
command -v python3 &>/dev/null \
    || die "python3 is required (sudo apt-get install -y python3).
      install.sh's guards — old-repo detection, conflict backup and the config
      collision lint — are all written in python3, and running without them can
      overwrite real files (a template-mode dotfile replaces one silently)."

# ── 4b. Companion repo drop-in (before the lint/guard/backup block) ───────────
# The private companion repo (CUSTOM.md) owns one config file, which belongs at
# ~/.config/mise/conf.d/50-custom.toml. setup:custom-hookup also creates that
# link — but it runs inside [tasks.bootstrap], i.e. bootstrap step 12, which is
# AFTER everything below: the collision lint, the old-repo guard and the
# conflict backup would all be blind to the companion's entries on the run that
# first deploys them. Since ~/.ssh/config is a template-mode entry, and template
# mode overwrites a pre-existing real file silently (§2.26), that blindness
# costs a real file. Link it here when the clone already exists, so the normal
# step-4 apply deploys it under the protection of all three checks;
# setup:custom-hookup stays the fallback for a companion cloned later.
CUSTOM_DIR="${DOTFILES_CUSTOM_MISE_DIR:-$HOME/.dotfiles-custom-mise}"
CUSTOM_CONF="$CUSTOM_DIR/mise/config.custom.toml"
if [[ -f "$CUSTOM_CONF" ]]; then
    mkdir -p "$CONF/conf.d"
    DROPIN="$CONF/conf.d/50-custom.toml"
    if [[ -e "$DROPIN" && ! -L "$DROPIN" ]]; then
        warn "$DROPIN is a real file, not a link — leaving it alone"
    elif [[ "$(readlink "$DROPIN" 2>/dev/null || true)" == "$CUSTOM_CONF" ]]; then
        ok "Companion repo already linked into conf.d"
    else
        ln -sfn "$CUSTOM_CONF" "$DROPIN"
        LINKED_DROPIN="$DROPIN"
        ok "Linked the companion repo: $DROPIN -> $CUSTOM_CONF"
    fi

    # The backup itself is DEFERRED to backup_companion_targets(), called after
    # guard_old_repo further down. Doing it here moved files before that guard
    # had run, so on a machine still carrying the old stow deployment a
    # companion target that is a real file underneath an old-repo directory
    # symlink would have been mv'd INSIDE the rollback path — the one thing
    # this script promises never to do. Linking early is still right (the lint,
    # the guard and the conflict backup all need to see the companion's
    # entries); only the mutation waits.
fi

# ONLY on the run that creates the link. A template-mode target is a real file
# once rendered, so an unconditional pass re-archives ~/.ssh/config on every
# single run — CI's idempotency check caught exactly that (`config.pre-mise.bak1`
# appearing on run 2). Afterwards, drift is backup_conflicts' job, and it keys
# on `state: differs`, which a freshly-rendered file does not have. Same
# reasoning as the task's FIRST_LINK gate.
#
# Keyed on the companion's config file rather than on `mise dotfiles status`:
# the status view of a just-created drop-in proved unreliable — observed in
# repeated sandbox runs of setup:custom-hookup, where status omitted the new
# entries while the apply moments later honoured them — and the entry it would
# miss is the template-mode ~/.ssh/config, which overwrites a real file with no
# error and no backup (§2.26).
backup_companion_targets() {
    [[ -n "${LINKED_DROPIN:-}" ]] || return 0
    local target expanded bak n old_hit
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        expanded="${target/#\~/$HOME}"
        [[ -e "$expanded" && ! -L "$expanded" ]] || continue
        # Self-guard, not just the caller's guard_old_repo: that one enumerates
        # via `mise dotfiles status`, which can omit this drop-in's entries, so
        # it may not have vetted this exact target. mv-ing a file that resolves
        # into an old repo would move it INTO the rollback path, and applying
        # would overwrite it there — the one thing this script must never do.
        if old_hit="$(target_resolves_into_old_repo "$target")"; then
            die "Companion target $target resolves into an old stow repo ($old_hit).
       Unstow the old repo(s) first (MIGRATION.md step 3), then re-run — backing
       this up would move a file into the rollback path."
        fi
        bak="$expanded.pre-mise.bak"
        n=1
        while [[ -e "$bak" ]]; do bak="$expanded.pre-mise.bak$((n++))"; done
        warn "Backing up $target -> $bak (declared by the companion repo)"
        mv "$expanded" "$bak" || warn "Could not move $expanded aside"
    done < <(python3 "$REPO/scripts/dotfiles-targets.py" "$CUSTOM_CONF" || true)
}

# ── 5. Validate config before handing over to mise ────────────────────────────
run_lint() {
    # rc 0 = clean, 1 = real problem (fatal), 2 = the linter could not run at
    # all (no tomllib: Python < 3.11, i.e. Ubuntu 22.04). A missing stdlib
    # module must not stop a machine from being installed — but it does mean
    # this install gets no collision checking, so say so loudly.
    local rc=0
    python3 "$REPO/scripts/lint-config.py" "$@" || rc=$?
    case "$rc" in
        0) return 0 ;;
        2)
            warn "Config lint unavailable on this python — continuing WITHOUT collision checking."
            warn "(Install python3.11+ or python3-tomli to get it back.)"
            return 0
            ;;
        *) return 1 ;;
    esac
}

run_lint || {
    warn "Config collision lint failed — fix before bootstrapping."
    exit 1
}
# Machine-local drop-ins live outside the repo now; a single broken one
# aborts every dotfiles apply, so check them too.
run_lint --live || {
    # A drop-in THIS RUN created, that then fails the lint, must not be left
    # behind: an entry with a missing source aborts every later `mise
    # dotfiles apply` on the machine, main repo included (§2.16). Only
    # unlink what we linked — never a file the user placed by hand.
    if [[ -n "${LINKED_DROPIN:-}" && -L "$LINKED_DROPIN" ]]; then
        rm -f "$LINKED_DROPIN"
        warn "Removed $LINKED_DROPIN again — it is what the lint rejected."
    fi
    warn "Machine-local mise config under $CONF failed the lint — fix before bootstrapping."
    exit 1
}

# ── 6. Trust + back up conflicting dotfile targets ────────────────────────────
mise trust "$REPO/mise/config.toml" >/dev/null
# Machine-local files can end up untrusted depending on how mise resolves the
# global config, and one untrusted file errors out every later mise call.
# Trusting the directory is not enough — each file needs it (2026.7.7).
shopt -s nullglob
for f in "$CONF"/config*.toml "$CONF"/conf.d/*.toml; do
    [[ -f "$f" ]] || continue
    mise trust "$f" >/dev/null 2>&1 || true
done
shopt -u nullglob
# On a first run the repo config isn't linked into ~/.config/mise yet, so mise
# only sees the [dotfiles] set when pointed at it explicitly — without this the
# probe below silently finds nothing to back up.
export MISE_GLOBAL_CONFIG_FILE="$REPO/mise/config.toml"
# mise refuses to replace existing real files (and --force would replace them
# WITHOUT backup — on the self-managed config entries it would even overwrite
# the repo's own files with symlink loops), so move aside any symlink-mode
# target that exists and differs: the skel ~/.bashrc on a fresh account, or
# files restored from stow backups during a cutover from the old repo.
cd "$HOME" # keep any project-local mise.toml in the caller's cwd out of scope

# ── 6b. Refuse to deploy on top of the OLD repo's stow symlinks ───────────────
# The predecessor repo (~/.dotfiles, GNU Stow) deploys whole DIRECTORIES as
# symlinks: ~/.config/bat, ~/.config/tmux, ~/.config/yazi and friends point into
# its working tree. A managed target underneath one of those resolves INTO the
# old clone, so applying here would either replace an old-repo tracked file with
# a symlink (mise converges same-content files without --force) or move it aside
# to .pre-mise.bak — inside the old repo. That repo is the documented rollback
# path, so corrupting it is the one failure this script must not allow.
# MIGRATION.md step 3 (unstow first) is the fix; this makes it enforced rather
# than merely documented.
#
# Called TWICE: once here (only config.toml is visible — MISE_GLOBAL_CONFIG_FILE
# restricts mise to that one file, §2.12) and again after it is unset, when the
# profile files' entries — ~/.config/yazi, ~/.config/ghostty/* — finally show
# up. Checking once would miss exactly those, and a stow *directory* symlink is
# replaced by mise without a conflict error (a symlink is never data to mise),
# i.e. silently.
# The real, symlink-free paths of the old stow repos (each is the documented
# rollback path for this migration).
old_repo_reals() {
    [[ -d "$OLD_REPO" ]] && (cd "$OLD_REPO" && pwd -P)
    [[ -d "$OLD_CUSTOM_REPO" ]] && (cd "$OLD_CUSTOM_REPO" && pwd -P)
}

# Does <target> resolve, through its nearest existing ancestor, INTO an old
# repo? Echoes the resolved old-repo path and returns 0 on a match; returns 1
# otherwise. Shared by guard_old_repo and backup_companion_targets — the latter
# needs its OWN check because it reads the companion's targets straight from the
# TOML (not from `mise dotfiles status`, which is unreliable for a just-created
# drop-in and can hide exactly the template-mode ~/.ssh/config that must never
# be mv'd into the old repo).
target_resolves_into_old_repo() {
    local target="$1" expanded probe resolved r
    expanded="${target/#\~/$HOME}"
    # Walk up to the nearest existing ancestor: the symlink is usually a parent
    # directory, not the target itself (which doesn't exist yet). `! -e && ! -L`
    # so a BROKEN symlink stops the walk (‑e is false for a dangling link) —
    # otherwise a stale stow symlink pointing into the old repo is stepped past
    # and missed.
    probe="$expanded"
    while [[ ! -e "$probe" && ! -L "$probe" && "$probe" != "/" && "$probe" != "$HOME" ]]; do
        probe="$(dirname "$probe")"
    done
    resolved="$(readlink -f "$probe" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || return 1
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        [[ "$resolved" == "$r"/* ]] && {
            printf '%s' "$resolved"
            return 0
        }
    done < <(old_repo_reals)
    return 1
}

guard_old_repo() {
    [[ -d "$OLD_REPO" || -d "$OLD_CUSTOM_REPO" ]] || return 0
    local conflicts=() target resolved
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        if resolved="$(target_resolves_into_old_repo "$target")"; then
            conflicts+=("$target -> $resolved")
        fi
    done < <(
        # [dotfiles] targets …
        { mise dotfiles status --json 2>/dev/null || true; } \
            | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
# Defensive: a non-dict payload or a file entry missing "target" must not throw
# — an exception here runs inside <(…), so it is swallowed and SILENTLY DISABLES
# the guard (the sibling repos branch already guards its shape; match it).
if not isinstance(data, dict):
    sys.exit(0)
for f in data.get("files", []):
    if isinstance(f, dict) and f.get("target"):
        print(f["target"])
'
        # … and [bootstrap.repos] paths, which are cloned/fetched in an EARLIER
        # bootstrap step than dotfiles. ~/.tmux is a stow symlink into the old
        # repo's oh-my-tmux submodule on a machine that hasn't unstowed yet, so
        # a repos apply would run git inside that submodule's working tree.
        { mise bootstrap repos status --json 2>/dev/null || true; } \
            | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
if isinstance(data, dict):
    data = data.get("repos", data.get("items", []))
for r in data if isinstance(data, list) else []:
    if isinstance(r, dict):
        p = r.get("path") or r.get("target") or r.get("dir")
        if p:
            print(p)
'
    )

    if ((${#conflicts[@]})); then
        warn "These paths currently resolve INTO an old stow repo ($(old_repo_reals | paste -sd' ' -)):"
        for target in "${conflicts[@]}"; do warn "    $target"; done
        die "Unstow the old repo(s) first (MIGRATION.md step 3), then re-run this script.
       Applying now would rewrite files inside them — the rollback path.
       Override with DOTFILES_OLD_REPO / DOTFILES_OLD_CUSTOM_REPO=/nonexistent
       only if you know better."
    fi
}

if [[ -d "$OLD_REPO" || -d "$OLD_CUSTOM_REPO" ]] && ! command -v python3 &>/dev/null; then
    die "python3 is required to check whether the old repos are still deployed.
      Without that check this script could rewrite files inside the old repo —
      the documented rollback path. Install python3 (apt install python3), or
      unstow the old repo and re-run with DOTFILES_OLD_REPO=/nonexistent."
fi
guard_old_repo

# Also runs twice, for the same reason as guard_old_repo: under
# MISE_GLOBAL_CONFIG_FILE the profile files' entries are invisible, so a
# pre-existing real ~/.config/yazi would never be backed up and pass 2 would
# die on the conflict — recommending --force, the one flag that is never safe
# here (§2.13).
backup_conflicts() {
    command -v python3 &>/dev/null || return 0
    # `|| true`: a status failure must not kill the script via pipefail — the
    # backup pass is best-effort, and bootstrap below reports the real problem.
    { mise dotfiles status --json 2>/dev/null || true; } \
        | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    # mise refused to report (e.g. an untrusted or broken config): skip the
    # backup pass rather than crashing — bootstrap will surface the real error.
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
# This pipeline runs in the FOREGROUND under `set -euo pipefail`, so an
# exception would abort install.sh mid-backup. Guard the shape.
if not isinstance(data, dict):
    sys.exit(0)
for f in data.get("files", []):
    if not isinstance(f, dict):
        continue
    # Any mode, not just symlink. A template-mode entry OVERWRITES a
    # pre-existing real file silently — no error, no backup (verified
    # 2026-07-20 against ~/.ssh/config) — where symlink mode at least
    # refuses. Backing up every differing target is the only defence.
    if f.get("state") == "differs" and f.get("target"):
        print(f["target"])
' \
        | while IFS= read -r target; do
            expanded="${target/#\~/$HOME}"
            [[ -e "$expanded" && ! -L "$expanded" ]] || continue
            bak="$expanded.pre-mise.bak"
            n=1
            while [[ -e "$bak" ]]; do bak="$expanded.pre-mise.bak$((n++))"; done
            warn "Backing up conflicting $target -> $bak"
            # A failing mv must not abort the pass half-done under set -e.
            mv "$expanded" "$bak" || warn "Could not move $expanded aside — bootstrap may refuse it"
        done
}

backup_conflicts

# ── 7. Bootstrap (two passes on a first run) ──────────────────────────────────
# MISE_GLOBAL_CONFIG_FILE doesn't just relocate config.toml — it suppresses the
# whole sibling family, so config.<profile>.toml and conf.d/*.toml are NOT
# loaded while it is set. Pass 1 therefore only creates the config links; pass 2
# runs without the variable, with the profiles this machine selected actually in
# effect. (Verified on 2026.7.7 — a single pass would install core only.)
YES=()
[[ "$NONINTERACTIVE" == "1" ]] && YES=(--yes)

if [[ -L "$CONF/config.toml" ]]; then
    ok "mise config already linked — skipping the link-only pass"
else
    info "Linking mise's own config into ~/.config/mise..."
    mise bootstrap --only dotfiles "${YES[@]}"
fi

unset MISE_GLOBAL_CONFIG_FILE
# Re-trust now that the linked files are what mise will resolve.
mise trust "$CONF/config.toml" >/dev/null 2>&1 || true

# Second look, now that the profile files are loaded: their [dotfiles] entries
# were invisible above, and pass 2 is what applies them.
guard_old_repo
# Back up what the companion is about to overwrite, HERE — after the var is
# unset (so the drop-in is fully visible) and after guard_old_repo, and right
# before pass 2 applies it. Pass 1 (--only dotfiles under MISE_GLOBAL_CONFIG_FILE)
# never applies the companion, so nothing was at risk earlier; pass 2 does, and
# backup_companion_targets self-guards against the old repo besides.
backup_companion_targets
backup_conflicts

# ── 7b. Repo health ───────────────────────────────────────────────────────────
# `mise bootstrap` exits 1 at its repos step (step 2 of 11) if ANY declared
# clone is dirty, and then never reaches dotfiles, tools or the imperative tail
# (verified 2026-07-21: one untracked, non-gitignored file is enough —
# `mise ERROR repos: ~/x has local changes`). This is easy to hit in practice:
# oh-my-zsh creates ~/.oh-my-zsh/completions/, and generated `_tool` completion
# files land inside the plugin clones — both are true on the author's laptop
# right now. mise's own message names one path and offers no remedy, so
# diagnose it here rather than half-configuring the machine.
guard_repo_health() {
    command -v python3 &>/dev/null || return 0
    local rows=() row path state
    mapfile -t rows < <(
        { mise bootstrap repos status --json 2>/dev/null || true; } \
            | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
for r in data.get("repos", []):
    if r.get("state") in ("dirty", "conflict"):
        print("%s|%s" % (r.get("state"), r.get("path")))
'
    )
    ((${#rows[@]})) || return 0
    warn "These [bootstrap.repos] clones would abort the bootstrap at its repos step:"
    for row in "${rows[@]}"; do
        state="${row%%|*}"
        path="${row#*|}"
        warn "    [$state] $path"
    done
    die "Clean them first: mise refuses to touch a repo with local changes, and that
      failure aborts everything after it (dotfiles, tools, the whole task chain).
        git -C <path> status                             # what is it?
        git -C <path> clean -nd                          # dry-run; drop -n to delete
        printf '<name>\\n' >> <path>/.git/info/exclude    # if it is generated
      The last is the right answer for generated completions: mise treats a
      gitignored file as clean (verified), and .git/info/exclude is local to the
      clone, so it needs no upstream change. \`mise run update:repos\` reports the
      same set later on."
}
guard_repo_health

info "Running mise bootstrap..."
mise bootstrap "${YES[@]}"

echo
ok "Done. Day-to-day from any directory:"
echo "    mise bootstrap status      # what's missing"
echo "    mise bootstrap --yes       # converge after editing config or profiles"
echo "    \$EDITOR $MISERC   # change this machine's profiles"
