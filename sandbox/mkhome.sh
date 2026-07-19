#!/usr/bin/env bash
# Build a throwaway $HOME and run mise bootstrap checks against this repo
# WITHOUT touching the real home directory.
#
# Usage:
#   sandbox/mkhome.sh [--keep] [--profiles "graphical,ai,dev"] [--] [mise args...]
#
# Default action is `mise bootstrap status`; pass extra args to run something
# else, e.g.:
#   sandbox/mkhome.sh -- dotfiles apply --dry-run
#   PROFILES=graphical,gnome sandbox/mkhome.sh -- bootstrap --only dotfiles --dry-run
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES="${PROFILES:-}"
KEEP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        --profiles) PROFILES="$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-mise-sandbox.XXXXXX")"
[[ $KEEP -eq 1 ]] || trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

# The repo's config declares dotfiles.root under ~/.dotfiles-mise, so mirror
# the repo into the sandbox home at the same relative location via symlink.
ln -s "$REPO" "$HOME/.dotfiles-mise"
ln -s "$HOME/.dotfiles-mise/mise" "$XDG_CONFIG_HOME/mise"

if [[ -n "$PROFILES" ]]; then
    printf 'env = [%s]\n' "$(printf '"%s", ' ${PROFILES//,/ } | sed 's/, $//')" \
        > "$XDG_CONFIG_HOME/mise/miserc.toml.sandbox"
    # miserc.toml lives inside the (symlinked) repo mise/ dir and is gitignored;
    # never clobber a real one the developer machine may have.
    if [[ -e "$XDG_CONFIG_HOME/mise/miserc.toml" ]]; then
        echo "WARN: mise/miserc.toml already exists in repo — sandbox uses it as-is" >&2
        rm -f "$XDG_CONFIG_HOME/mise/miserc.toml.sandbox"
    else
        mv "$XDG_CONFIG_HOME/mise/miserc.toml.sandbox" "$XDG_CONFIG_HOME/mise/miserc.toml"
        trap 'rm -f "'"$REPO"'/mise/miserc.toml"; [[ '"$KEEP"' -eq 1 ]] || rm -rf "'"$SANDBOX"'"' EXIT
    fi
fi

cd "$HOME"
mise trust "$XDG_CONFIG_HOME/mise/config.toml" >/dev/null 2>&1 || true

echo "── sandbox HOME: $HOME (keep=$KEEP, profiles=${PROFILES:-none}) ──" >&2
if [[ $# -gt 0 ]]; then
    mise "$@"
else
    mise bootstrap status
fi
