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
        if command -v gh &>/dev/null; then
            read -rp "Run 'gh auth login' now? [Y/n] " a
            if [[ ! "$a" =~ ^[Nn]$ ]]; then
                gh auth login
                MISE_GITHUB_TOKEN="$(gh auth token)"
                export MISE_GITHUB_TOKEN
            fi
        else
            warn "Install gh or export GITHUB_TOKEN=ghp_... then re-run this script."
            read -rp "Continue anyway (best effort)? [y/N] " a
            [[ "$a" =~ ^[Yy]$ ]] || exit 1
        fi
    fi
else
    ok "GitHub token already set (\$MISE_GITHUB_TOKEN)"
fi

# ── 3. ~/.config/mise → repo symlink ──────────────────────────────────────────
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/mise"
if [[ -L "$CONF" && "$(readlink -f "$CONF")" == "$REPO/mise" ]]; then
    ok "~/.config/mise already points at the repo"
else
    if [[ -e "$CONF" ]]; then
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
        echo "Available profiles: graphical gnome cosmic ai dev yazi neovim media veracrypt laptop desktop"
        read -rp "Profiles for this machine (comma-separated, empty = core only): " PROFILES
    fi
    {
        echo "# Per-machine profile selection — see miserc.example.toml"
        if [[ -n "$PROFILES" ]]; then
            printf 'env = ['
            first=1
            IFS=',' read -ra parts <<<"$PROFILES"
            for p in "${parts[@]}"; do
                p="$(echo "$p" | tr -d '[:space:]')"
                [[ -z "$p" ]] && continue
                [[ $first -eq 1 ]] || printf ', '
                printf '"%s"' "$p"
                first=0
            done
            printf ']\n'
        else
            echo 'env = []'
        fi
    } >"$MISERC"
    ok "Wrote mise/miserc.toml (profiles: ${PROFILES:-none})"
fi

# ── 5. Validate config before handing over to mise ────────────────────────────
if command -v python3 &>/dev/null; then
    python3 "$REPO/scripts/lint-config.py" || {
        warn "Config collision lint failed — fix before bootstrapping."
        exit 1
    }
fi

# ── 6. Trust + bootstrap ──────────────────────────────────────────────────────
mise trust "$REPO/mise/config.toml" >/dev/null
info "Running mise bootstrap..."
if [[ "$NONINTERACTIVE" == "1" ]]; then
    mise bootstrap --yes
else
    mise bootstrap
fi
