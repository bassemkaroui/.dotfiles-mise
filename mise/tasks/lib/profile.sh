# shellcheck shell=bash
# Shared helpers for the file tasks in this repo.
#
# Usage: set TASK_NAME before sourcing.
#   TASK_NAME="setup:completions"
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/profile.sh"
#
# The relative path resolves through ~/.config/mise/tasks, which is a symlink
# to this repo's mise/tasks (D1a self-management), so it works both from the
# repo and from a deployed machine. Files in lib/ are not executable and mise
# does not list them as tasks (verified).

: "${TASK_NAME:=unknown}"

_pad=26 # column width for task-name alignment

info() { printf '\033[1;34m[INFO]\033[0m \033[36m%-*s\033[0m ▸ %s\n' "$_pad" "$TASK_NAME" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m \033[36m%-*s\033[0m ▸ %s\n' "$_pad" "$TASK_NAME" "$*"; }
ok() { printf '\033[1;32m[ OK ]\033[0m \033[36m%-*s\033[0m ▸ %s\n' "$_pad" "$TASK_NAME" "$*"; }
ok_changed() { printf '\033[1;32m[ OK ]\033[0m \033[36m%-*s\033[0m \033[1;32m●\033[0m %s\n' "$_pad" "$TASK_NAME" "$*"; }
fail() {
    printf '\033[1;31m[FAIL]\033[0m \033[36m%-*s\033[0m ▸ %s\n' "$_pad" "$TASK_NAME" "$*"
    exit 1
}

# ─── Shared paths ─────────────────────────────────────────────────────────────

# shellcheck disable=SC2034  # REPO/CONF are part of this lib's API, used by sourcing tasks
REPO="${DOTFILES_MISE_REPO:-$HOME/.dotfiles-mise}"
CONF="${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}"

# ─── Profile gating ───────────────────────────────────────────────────────────
#
# A machine opts into capability groups in ~/.config/mise/miserc.toml
# (`env = ["graphical", "dev", ...]`), which mise exposes to file tasks as a
# comma-separated $MISE_ENV. This replaces the old repo's six per-machine state
# files (.device-tag, .graphical-env, .desktop-env, .stow-exclude,
# .mise-conf-exclude, .install-exclude).
#
# Gating MUST live in tasks: $MISE_ENV does not reach [bootstrap.hooks]
# (verified 2026-07-19), so a hook can never be profile-aware.

# has_profile <name> — true when <name> is in $MISE_ENV.
has_profile() {
    local want="$1" have
    IFS=',' read -ra have <<<"${MISE_ENV:-}"
    local p
    for p in "${have[@]}"; do
        [[ "$p" == "$want" ]] && return 0
    done
    return 1
}

# require_profile <name> — for a task that is a no-op without <name>: logs why
# it is skipping and exits 0 (a skipped optional step is not a failed bootstrap).
require_profile() {
    if ! has_profile "$1"; then
        info "profile '$1' not selected on this machine — skipping"
        info "(enable it in ${CONF}/miserc.toml, then re-run: mise bootstrap --yes)"
        exit 0
    fi
}
