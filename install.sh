#!/usr/bin/env bash
# Bootstrap entry point — the only imperative step that runs before mise owns
# the machine. Everything here must stay idempotent.
#
#   git clone https://github.com/bassemkaroui/.dotfiles-mise.git ~/.dotfiles-mise
#   ~/.dotfiles-mise/install.sh
#
# Env:
#   DOTFILES_PROFILES=graphical,ai,dev   seed mise/miserc.toml non-interactively
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

# ── 1. mise itself ────────────────────────────────────────────────────────────
if ! command -v mise &>/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    info "Installing mise..."
    curl -fsSL https://mise.run | sh
fi
export PATH="$HOME/.local/bin:$PATH"

# ── 2. GitHub token ───────────────────────────────────────────────────────────
# Installing [tools] resolves aqua/github-backed tools through the GitHub
# releases API (60 req/hr unauthenticated). The token must be exported HERE —
# in the parent process of `mise bootstrap` — hooks and tasks run too late.
gh_cmd() {
    # Run gh even before [tools] are installed: fall back to a one-off
    # mise-managed gh (single API call, fits the unauthenticated budget).
    if command -v gh &>/dev/null; then
        gh "$@"
    else
        mkdir -p "${GH_CONFIG_DIR:-$HOME/.config/gh}" # gh errors without it
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
        warn "No GitHub token found — tool installs may hit API rate limits."
        warn "Set GITHUB_TOKEN (a no-scope PAT is enough) and re-run if that happens."
    else
        warn "No GitHub token found. Tool installs hit the GitHub API and will"
        warn "be rate-limited without one (60 req/hr)."
        read -rp "Authenticate with GitHub now (gh auth login)? [Y/n] " a || a=n
        if [[ ! "$a" =~ ^[Nn]$ ]]; then
            gh_cmd auth login
            MISE_GITHUB_TOKEN="$(gh_cmd auth token)"
            export MISE_GITHUB_TOKEN
        else
            warn "Continuing without a token (best effort). If installs fail,"
            warn "export GITHUB_TOKEN=ghp_... (https://github.com/settings/tokens,"
            warn "no scopes needed) and re-run this script."
        fi
    fi
else
    ok "GitHub token already set (\$MISE_GITHUB_TOKEN)"
fi

# ── 3. ~/.config/mise → repo symlink ──────────────────────────────────────────
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/mise"
if [[ -L "$CONF" && "$(readlink -f "$CONF")" == "$(readlink -f "$REPO/mise")" ]]; then
    # shellcheck disable=SC2088  # tilde is literal display text, not a path to expand
    ok "~/.config/mise already points at the repo"
else
    # -L catches broken/foreign symlinks that -e alone would miss
    if [[ -e "$CONF" || -L "$CONF" ]]; then
        BAK="$CONF.bak.$(date +%Y%m%d%H%M%S)"
        warn "Backing up existing $CONF -> $BAK"
        mv "$CONF" "$BAK"
    fi
    mkdir -p "$(dirname "$CONF")"
    ln -s "$REPO/mise" "$CONF"
    ok "Symlinked ~/.config/mise -> $REPO/mise"
fi

# ── 4. Per-machine profile selection (miserc.toml) ────────────────────────────
MISERC="$REPO/mise/miserc.toml"
if [[ -f "$MISERC" ]]; then
    ok "mise/miserc.toml already present: $(grep -E '^env' "$MISERC" || echo '(no env line)')"
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
    ok "Wrote mise/miserc.toml (profiles: ${selected[*]:-none})"
fi

# ── 5. Validate config before handing over to mise ────────────────────────────
if command -v python3 &>/dev/null; then
    python3 "$REPO/scripts/lint-config.py" || {
        warn "Config collision lint failed — fix before bootstrapping."
        exit 1
    }
else
    warn "python3 not found — skipping config collision lint"
fi

# ── 6. Trust + back up conflicting dotfile targets ────────────────────────────
mise trust "$REPO/mise/config.toml" >/dev/null
# mise refuses to replace existing real files (and --force would replace them
# WITHOUT backup), so move aside any symlink-mode target that exists and
# differs — e.g. the skel ~/.bashrc on a fresh account, or files restored from
# stow backups during a cutover from the old repo.
cd "$HOME" # keep any project-local mise.toml in the caller's cwd out of scope
if command -v python3 &>/dev/null; then
    mise dotfiles status --json 2>/dev/null |
        python3 -c '
import json, sys
data = json.load(sys.stdin)
for f in data.get("files", []):
    if f.get("mode") == "symlink" and f.get("state") == "differs":
        print(f["target"])
' |
        while IFS= read -r target; do
            expanded="${target/#\~/$HOME}"
            [[ -e "$expanded" && ! -L "$expanded" ]] || continue
            bak="$expanded.pre-mise.bak"
            n=1
            while [[ -e "$bak" ]]; do bak="$expanded.pre-mise.bak$((n++))"; done
            warn "Backing up conflicting $target -> $bak"
            mv "$expanded" "$bak"
        done
fi

# ── 7. Bootstrap ──────────────────────────────────────────────────────────────
info "Running mise bootstrap..."
if [[ "$NONINTERACTIVE" == "1" ]]; then
    mise bootstrap --yes
else
    mise bootstrap
fi
