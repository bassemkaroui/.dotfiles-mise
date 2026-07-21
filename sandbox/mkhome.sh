#!/usr/bin/env bash
# Build a throwaway $HOME and run mise commands against this repo WITHOUT
# touching the real home directory or writing anything into the repo.
#
# Usage:
#   sandbox/mkhome.sh [--keep] [--two-pass] [--profiles "graphical,ai,dev"] [--] [mise args...]
#
# Default action is `mise bootstrap status`; pass extra args to run something
# else, e.g.:
#   sandbox/mkhome.sh -- dotfiles apply --dry-run
#   sandbox/mkhome.sh --profiles graphical,gnome -- bootstrap --only dotfiles --dry-run
#   sandbox/mkhome.sh --two-pass --profiles gnome -- dotfiles status
#
# --two-pass mirrors install.sh's real first run: link the config family with
# `bootstrap --only dotfiles` under MISE_GLOBAL_CONFIG_FILE, then drop the
# variable. WITHOUT it the sandbox can only ever see CORE entries — the
# variable suppresses config.<profile>.toml (§2.12), so a profile-specific
# assertion made in single-pass mode silently passes for the wrong reason.
#
# The sandbox mirrors the real first-run flow: ~/.config/mise is a real
# directory holding a machine-local miserc.toml, and mise is pointed at the
# repo's config with MISE_GLOBAL_CONFIG_FILE (which is what install.sh does
# before the config links exist).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# NOT "${PROFILES:-}": inheriting a caller's $PROFILES silently activated
# profiles nobody asked this run for, and the banner then reported them as if
# they had been requested. Only --profiles selects.
PROFILES=""
KEEP=0
TWO_PASS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            KEEP=1
            shift
            ;;
        --two-pass)
            TWO_PASS=1
            shift
            ;;
        --profiles)
            PROFILES="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *) break ;;
    esac
done

# This shell (and any parent that ran `mise activate`) may export MISE_* vars
# that silently point the sandbox back at the REAL config: MISE_TRUSTED_CONFIG_PATHS
# is set to ~/.config/mise on the author's machine, which would make every
# sandbox inherit trust it should have had to establish itself — exactly the
# class of behaviour (§2.10) this harness exists to reproduce.
unset MISE_TRUSTED_CONFIG_PATHS MISE_GLOBAL_CONFIG_FILE MISE_CONFIG_DIR MISE_ENV \
    MISE_DATA_DIR MISE_STATE_DIR MISE_CACHE_DIR

# Not only MISE_*. These three redirect tools at the REAL user state regardless
# of $HOME, which is the one thing this harness exists to prevent: a sandboxed
# gpg:* task passes no --homedir and relies entirely on $HOME redirection, so an
# exported GNUPGHOME would point it at the real keyring.
unset GNUPGHOME GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

# mise resolves `<ancestor>/.config/mise/config.toml` from the CWD, independent
# of $HOME (verified: cd / → clean; cd ~/anything with $HOME set elsewhere →
# the REAL ~/.config/mise/config.toml is loaded as a project config). The
# sandbox cds into its own $HOME below, so this only matters if that $HOME sits
# under the real one — which is exactly what TMPDIR=$HOME/tmp would do, and
# every assertion in this harness would then be silently contaminated by the
# real machine's config.
TMPDIR=/tmp
export TMPDIR

SANDBOX="$(mktemp -d "$TMPDIR/dotfiles-mise-sandbox.XXXXXX")"
[[ $KEEP -eq 1 ]] || trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$XDG_CONFIG_HOME/mise" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

# The repo's config uses ~/.dotfiles-mise paths (dotfiles.root and the
# self-management sources), so expose it there inside the sandbox.
ln -s "$REPO" "$HOME/.dotfiles-mise"

# Machine-local profile selection — written into the sandbox, never the repo.
{
    echo "# sandbox miserc"
    if [[ -n "$PROFILES" ]]; then
        printf 'env = ['
        first=1
        for p in ${PROFILES//,/ }; do
            [[ $first -eq 1 ]] || printf ', '
            printf '"%s"' "$p"
            first=0
        done
        printf ']\n'
    else
        echo 'env = []'
    fi
} >"$XDG_CONFIG_HOME/mise/miserc.toml"

# Before the config links exist, point mise at the repo config directly — the
# same mechanism install.sh uses on a first run.
export MISE_GLOBAL_CONFIG_FILE="$REPO/mise/config.toml"

cd "$HOME"
mise trust "$REPO/mise/config.toml" >/dev/null 2>&1 || true

echo "── sandbox HOME: $HOME (keep=$KEEP, two-pass=$TWO_PASS, profiles=${PROFILES:-none}) ──" >&2

if [[ $TWO_PASS -eq 1 ]]; then
    mise bootstrap --only dotfiles --yes >/dev/null
    unset MISE_GLOBAL_CONFIG_FILE
    mise trust "$XDG_CONFIG_HOME/mise/config.toml" >/dev/null 2>&1 || true
fi
if [[ $# -gt 0 ]]; then
    mise "$@"
else
    mise bootstrap status
fi
