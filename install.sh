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
[[ "$(readlink -f "$REPO")" == "$(readlink -f "$HOME/.dotfiles-mise")" ]] ||
    die "This repo must live at ~/.dotfiles-mise (found: $REPO).
      The [dotfiles] entries in mise/config.toml hardcode that path.
      Move the clone, or edit those entries and dotfiles.root to match."
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/mise"
[[ "$CONF" == "$HOME/.config/mise" ]] ||
    die "XDG_CONFIG_HOME points mise config at $CONF, but mise/config.toml
      targets ~/.config/mise literally. Unset XDG_CONFIG_HOME or edit those entries."

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
        rmdir "$src/conf.d" 2>/dev/null ||
            warn "$src/conf.d still has files — left in place, move them to $CONF/conf.d/ by hand"
    fi
    shopt -u nullglob
}

LEGACY_SRC=""
if [[ -L "$CONF" ]]; then
    LINK_TARGET="$(readlink -f "$CONF" || true)"
    # Any clone of this repo (not just $REPO) looks like: config.toml + tasks/
    if [[ -f "$LINK_TARGET/config.toml" && -d "$LINK_TARGET/tasks" ]]; then
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

# ── 5. Validate config before handing over to mise ────────────────────────────
if command -v python3 &>/dev/null; then
    python3 "$REPO/scripts/lint-config.py" || {
        warn "Config collision lint failed — fix before bootstrapping."
        exit 1
    }
    # Machine-local drop-ins live outside the repo now; a single broken one
    # aborts every dotfiles apply, so check them too.
    python3 "$REPO/scripts/lint-config.py" --live || {
        warn "Machine-local mise config under $CONF failed the lint — fix before bootstrapping."
        exit 1
    }
else
    warn "python3 not found — skipping config collision lint"
fi

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
if command -v python3 &>/dev/null; then
    # `|| true`: a status failure must not kill the script via pipefail — the
    # backup pass is best-effort, and bootstrap below reports the real problem.
    { mise dotfiles status --json 2>/dev/null || true; } |
        python3 -c '
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
            # A failing mv must not abort the pass half-done under set -e.
            mv "$expanded" "$bak" || warn "Could not move $expanded aside — bootstrap may refuse it"
        done
fi

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

info "Running mise bootstrap..."
mise bootstrap "${YES[@]}"

echo
ok "Done. Day-to-day from any directory:"
echo "    mise bootstrap status      # what's missing"
echo "    mise bootstrap --yes       # converge after editing config or profiles"
echo "    \$EDITOR $MISERC   # change this machine's profiles"
