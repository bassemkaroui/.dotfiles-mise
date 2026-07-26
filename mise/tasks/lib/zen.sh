# shellcheck shell=bash
# Zen browser install/update helpers, shared by install:zen and update:zen.
# Source AFTER lib/profile.sh — it needs info/warn/ok/ok_changed/skip/have/
# gh_curl.
#
# Same shape as lib/obsidian.sh, and deliberately a separate file rather than a
# generalisation of it: folding both into one lib/appimage.sh is the right end
# state, but rewriting a working, already-bug-fixed installer is a change that
# deserves its own review rather than riding along with a new app.

ZEN_REPO="zen-browser/desktop"
ZEN_BIN="$HOME/.local/bin/zen"
ZEN_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zen"
ZEN_VERSION_FILE="$ZEN_STATE_DIR/version"
ZEN_DESKTOP_FILE="$HOME/.local/share/applications/zen.desktop"
ZEN_ICON_FILE="$HOME/.local/share/icons/hicolor/256x256/apps/zen.png"

# Cached latest-release JSON (populated by zen_fetch_release).
ZEN_RELEASE_JSON=""

zen_fetch_release() {
    [[ -n "$ZEN_RELEASE_JSON" ]] && return 0
    ZEN_RELEASE_JSON="$(gh_curl -fsSL "https://api.github.com/repos/$ZEN_REPO/releases/latest")" || return 1
    [[ -n "$ZEN_RELEASE_JSON" ]]
}

# Echo the latest version tag. Zen's tags carry non-numeric suffixes ("1.21.9b"),
# so every comparison against this value must be string EQUALITY — never a
# numeric or version sort.
zen_latest_version() {
    printf '%s' "$ZEN_RELEASE_JSON" \
        | grep '"tag_name"' | head -1 | sed -E 's/.*"v?([^"]+)".*/\1/'
}

# Echo the AppImage download URL for this machine's architecture.
#
# The trailing-quote anchor is load-bearing: every Zen release ships
# `zen-x86_64.AppImage` AND `zen-x86_64.AppImage.zsync` (an rsync-style delta
# index, not a runnable binary). Without the anchor the grep matches both and
# head -1 picks whichever GitHub lists first.
zen_appimage_url() {
    local pattern
    case "$(uname -m)" in
        x86_64) pattern='zen-x86_64\.AppImage"' ;;
        aarch64 | arm64) pattern='zen-aarch64\.AppImage"' ;;
        *) return 0 ;;
    esac
    printf '%s' "$ZEN_RELEASE_JSON" \
        | grep '"browser_download_url"' \
        | grep -E "$pattern" \
        | head -1 \
        | sed -E 's/.*"(https[^"]+)".*/\1/'
}

zen_installed_version() {
    [[ -f "$ZEN_VERSION_FILE" && -x "$ZEN_BIN" ]] || return 0
    tr -d '[:space:]' <"$ZEN_VERSION_FILE"
}

# Best-effort menu integration. Never fatal: AppImage extraction fails on
# FUSE-less hosts, where the launcher just gets a blank icon.
zen_desktop_integration() {
    local version="$1" extract_dir icon
    mkdir -p "$(dirname "$ZEN_DESKTOP_FILE")" "$(dirname "$ZEN_ICON_FILE")"

    extract_dir="$(mktemp -d)"
    if (cd "$extract_dir" && "$ZEN_BIN" --appimage-extract >/dev/null 2>&1); then
        icon="$(find "$extract_dir/squashfs-root" -maxdepth 2 -name '*.png' 2>/dev/null | head -1)"
        if [[ -n "$icon" ]]; then
            cp "$icon" "$ZEN_ICON_FILE"
            ok "Installed the Zen icon"
        else
            warn "No icon found in the Zen AppImage — the menu entry may show a blank icon"
        fi
    else
        warn "Could not extract the Zen icon — the menu entry may show a blank icon"
    fi
    rm -rf "$extract_dir"

    cat >"$ZEN_DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Zen Browser
Comment=Calm internet browser
Exec=$ZEN_BIN %u
Icon=zen
Terminal=false
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupWMClass=zen
X-Zen-Version=$version
EOF
    ok "Wrote the desktop launcher: $ZEN_DESKTOP_FILE"

    if have update-desktop-database; then
        update-desktop-database "$(dirname "$ZEN_DESKTOP_FILE")" >/dev/null 2>&1 || true
    fi
}

# Download, verify, install, stamp the version, wire up the launcher.
# A download failure is environmental, so it `skip`s (exits 0) rather than
# aborting the bootstrap chain — call this from the task's main shell, not a
# subshell.
zen_install_appimage() {
    local version="$1" url="$2" tmp
    [[ -n "$url" ]] || skip "No Zen AppImage for architecture $(uname -m)"

    mkdir -p "$(dirname "$ZEN_BIN")" "$ZEN_STATE_DIR"

    tmp="$(mktemp)"
    info "Downloading Zen $version ..."
    if ! curl -fSL -o "$tmp" "$url"; then
        rm -f "$tmp"
        skip "Failed to download the Zen AppImage from $url"
    fi
    chmod +x "$tmp"
    # Prove it is an executable before recording it as the installed version.
    # lib/obsidian.sh had the bug this prevents: a truncated download or an
    # HTML error page was moved into place and stamped, after which every later
    # run reported "up to date" and never retried.
    if ! head -c 4 "$tmp" | grep -q $'\x7fELF'; then
        rm -f "$tmp"
        skip "The downloaded Zen AppImage is not an executable (truncated or an error page?)"
    fi
    mv "$tmp" "$ZEN_BIN"
    printf '%s\n' "$version" >"$ZEN_VERSION_FILE"
    ok_changed "Zen $version installed to $ZEN_BIN"

    zen_desktop_integration "$version"

    # Make zen resolvable in the current session.
    export PATH="$HOME/.local/bin:$PATH"
}
