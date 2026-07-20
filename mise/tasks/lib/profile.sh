# shellcheck shell=bash
# Shared helpers for the file tasks in this repo.
#
# Usage: set TASK_NAME before sourcing.
#   TASK_NAME="setup:completions"
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/profile.sh"
#
# The relative path resolves through ~/.config/mise/tasks, which is a symlink
# to this repo's mise/tasks (D1a self-management), so it works both from the
# repo and from a deployed machine. Files in lib/ are deliberately NOT
# executable: mise lists an executable file under tasks/lib/ as a task
# (`lib:foo` — verified), a non-executable one it ignores.

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

# ─── Degrading instead of failing ─────────────────────────────────────────────
#
# A `{ task = "x" }` entry in [tasks.bootstrap].run that exits non-zero ABORTS
# the rest of the chain and makes `mise bootstrap` exit with that code
# (verified 2026-07-20: a→b(exit 3)→c ran a and b, never c, rc=3). Every step
# after the failing one is lost — so an optional install that can't reach the
# network must never take completions, git signing or the login-shell fallback
# down with it.
#
# Rule for the ported install tasks: `fail` is for "this machine is in a state
# I refuse to guess about"; anything environmental (no network, no sudo, no
# desktop session, no upstream asset for this release) uses `skip`.

# skip <reason...> — warn and exit 0. The bootstrap continues.
skip() {
    warn "$*"
    exit 0
}

# ─── Capability probes ────────────────────────────────────────────────────────
#
# Profiles express POLICY ("this machine should have GNOME extensions"); they
# say nothing about CAPABILITY ("gnome-shell is installed and running right
# now"). The old repo conflated the two in its auto-detection; keeping the
# cheap runtime probes as skip-guards is what stops `mise bootstrap` from
# failing on a box whose desktop isn't installed yet (e.g. provisioning over
# SSH before the first graphical login).

# have <binary...> — true only when every named binary is on PATH.
have() {
    local b
    for b in "$@"; do
        command -v "$b" &>/dev/null || return 1
    done
    return 0
}

# sudo_ok — true when sudo can elevate here and now, leaving a cached timestamp
# behind so the caller's own `sudo -n` calls succeed.
#
# Two situations, two answers. Unattended (CI, provisioning, `curl | bash`) a
# password prompt is a hang, not an interaction, so `sudo -n` failing means
# "skip this step". At a real terminal, prompting is what the old repo did and
# what the user expects, and a chained task DOES inherit that terminal when
# bootstrap is run from one (verified under a pty). Gating on `sudo -n` alone
# would have made install:ghostty, install:veracrypt and setup:cosmic
# permanently inert, since it fails on any normal desktop account. `sudo -v`
# asks once and caches the timestamp for the caller's own `sudo -n` calls.
sudo_ok() {
    command -v sudo &>/dev/null || return 1
    sudo -n true 2>/dev/null && return 0
    [[ -t 0 ]] || return 1
    sudo -v
}

# gh_curl <curl args...> — curl with a GitHub token attached when one is
# available. install.sh exports a token for mise's own downloads, but a plain
# curl never picks it up, and these tasks all hit api.github.com (60 req/hr
# unauthenticated, shared with every other tool on the machine).
gh_curl() {
    local token="${MISE_GITHUB_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
    if [[ -z "$token" ]] && command -v gh &>/dev/null; then
        token="$(gh auth token 2>/dev/null || true)"
    fi
    if [[ -n "$token" ]]; then
        curl -H "Authorization: Bearer $token" "$@"
    else
        curl "$@"
    fi
}
