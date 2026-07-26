# shellcheck shell=bash
# Zen browser install/update helpers, shared by install:zen and update:zen.
# Source AFTER lib/profile.sh — it needs info/warn/ok/ok_changed/skip/have/
# gh_curl.
#
# ─── Why the tarball and not the AppImage ────────────────────────────────────
#
# Zen publishes both. The tarball is what its official installer
# (https://updates.zen-browser.app/install.sh) deploys, and it is the only one
# of the two the browser's BUILT-IN updater can service — an AppImage install
# has no in-place update path, so it would go stale between bootstraps and
# fight the updater rather than feed it.
#
# It is also what is already on the author's machine, which is how the first
# draft's bug was found: that draft installed the AppImage to ~/.local/bin/zen
# and wrote its own ~/.local/share/applications/zen.desktop — the exact two
# paths the official installer uses. It would have overwritten a working
# tarball install's launcher wrapper and its richer desktop entry (four Desktop
# Actions), and because the AppImage version stamp lived in a state file that a
# tarball install does not have, the "already installed" check would not even
# have fired first.
#
# So this mirrors the official installer's layout exactly, and adopts an
# existing install instead of replacing it.

ZEN_DIR="$HOME/.tarball-installations/zen"
ZEN_BIN="$HOME/.local/bin/zen"
ZEN_DESKTOP_FILE="$HOME/.local/share/applications/zen.desktop"

# Cached latest-release JSON (populated by zen_fetch_release).
ZEN_RELEASE_JSON=""

zen_fetch_release() {
    [[ -n "$ZEN_RELEASE_JSON" ]] && return 0
    ZEN_RELEASE_JSON="$(gh_curl -fsSL "https://api.github.com/repos/zen-browser/desktop/releases/latest")" || return 1
    [[ -n "$ZEN_RELEASE_JSON" ]]
}

# Echo the latest version tag. Zen's tags carry non-numeric suffixes ("1.21.9b"),
# so every comparison against this value must be string EQUALITY — never a
# numeric or version sort.
zen_latest_version() {
    printf '%s' "$ZEN_RELEASE_JSON" \
        | grep '"tag_name"' | head -1 | sed -E 's/.*"v?([^"]+)".*/\1/'
}

# Echo the tarball URL for this machine's architecture.
#
# The trailing-quote anchor matters here as much as it does for the AppImage
# assets: a release ships zen.linux-x86_64.tar.xz alongside .mar and .zsync
# siblings, and an unanchored match takes whichever GitHub lists first.
zen_tarball_url() {
    local pattern
    case "$(uname -m)" in
        x86_64) pattern='zen\.linux-x86_64\.tar\.xz"' ;;
        aarch64 | arm64) pattern='zen\.linux-aarch64\.tar\.xz"' ;;
        *) return 0 ;;
    esac
    printf '%s' "$ZEN_RELEASE_JSON" \
        | grep '"browser_download_url"' \
        | grep -E "$pattern" \
        | head -1 \
        | sed -E 's/.*"(https[^"]+)".*/\1/'
}

# Echo the installed version, read from the install itself.
#
# application.ini is written by the build, so it stays correct even when Zen's
# own updater upgrades in place behind our back — which a separate state file
# of ours would not. That is why there is no ~/.local/state/zen here.
zen_installed_version() {
    [[ -f "$ZEN_DIR/application.ini" ]] || return 0
    sed -n 's/^Version=//p' "$ZEN_DIR/application.ini" | head -1
}

# True when ~/.local/bin/zen is absent or is a launcher we can safely rewrite
# (i.e. it points into $ZEN_DIR). Anything else — a real binary, an AppImage, a
# wrapper into some other prefix — is someone else's install, and this task
# must not silently replace it.
zen_launcher_is_ours() {
    [[ -e "$ZEN_BIN" ]] || return 0
    grep -qF "$ZEN_DIR/zen" "$ZEN_BIN" 2>/dev/null
}

# Launcher wrapper + desktop entry, matching what Zen's official installer
# writes (including the four Desktop Actions — a plainer entry would be a
# downgrade for anyone migrating from it).
zen_write_launcher() {
    mkdir -p "$(dirname "$ZEN_BIN")" "$(dirname "$ZEN_DESKTOP_FILE")"

    cat >"$ZEN_BIN" <<EOF
#!/bin/bash
exec "$ZEN_DIR/zen" "\$@"
EOF
    chmod +x "$ZEN_BIN"

    cat >"$ZEN_DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Zen Browser
Comment=Experience tranquillity while browsing the web without people tracking you!
Keywords=web;browser;internet
Exec=$ZEN_DIR/zen %u
Icon=$ZEN_DIR/browser/chrome/icons/default/default128.png
Terminal=false
StartupNotify=true
StartupWMClass=zen
NoDisplay=false
Type=Application
MimeType=text/html;text/xml;application/xhtml+xml;application/vnd.mozilla.xul+xml;text/mml;x-scheme-handler/http;x-scheme-handler/https;
Categories=Network;WebBrowser;
Actions=new-window;new-blank-window;new-private-window;profile-manager-window;
[Desktop Action new-window]
Name=Open a New Window
Exec=$ZEN_DIR/zen --new-window %u
[Desktop Action new-blank-window]
Name=Open a New Blank Window
Exec=$ZEN_DIR/zen --blank-window %u
[Desktop Action new-private-window]
Name=Open a New Private Window
Exec=$ZEN_DIR/zen --private-window %u
[Desktop Action profile-manager-window]
Name=Open the Profile Manager
Exec=$ZEN_DIR/zen --ProfileManager
EOF

    if have update-desktop-database; then
        update-desktop-database "$(dirname "$ZEN_DESKTOP_FILE")" >/dev/null 2>&1 || true
    fi
}

# Download, verify, and swap in the given version.
#
# A download failure is environmental, so it `skip`s (exits 0) rather than
# aborting the bootstrap chain — call this from the task's main shell, not a
# subshell.
zen_install_tarball() {
    local version="$1" url="$2" tmp staging old
    [[ -n "$url" ]] || skip "No Zen tarball for architecture $(uname -m)"

    zen_launcher_is_ours || skip "$ZEN_BIN is not a launcher this task manages — leaving it alone"

    tmp="$(mktemp)"
    info "Downloading Zen $version ..."
    if ! curl -fSL -o "$tmp" "$url"; then
        rm -f "$tmp"
        skip "Failed to download the Zen tarball from $url"
    fi

    # Unpack to a staging dir and prove it is a Zen tree BEFORE touching the
    # live one. curl -f catches a bad response, not a truncated-but-200 body,
    # and the failure mode of getting this wrong is a browser that won't start.
    staging="$(mktemp -d)"
    if ! tar -xJf "$tmp" -C "$staging" 2>/dev/null; then
        rm -rf "$tmp" "$staging"
        skip "The downloaded Zen tarball could not be unpacked (truncated?)"
    fi
    rm -f "$tmp"
    if [[ ! -x "$staging/zen/zen" || ! -f "$staging/zen/application.ini" ]]; then
        rm -rf "$staging"
        skip "The Zen tarball does not contain the expected zen/ tree"
    fi

    mkdir -p "$(dirname "$ZEN_DIR")"
    # Move the old install aside rather than deleting it first: if the swap
    # fails halfway there is still something to put back.
    old=""
    if [[ -d "$ZEN_DIR" ]]; then
        old="$ZEN_DIR.replacing.$$"
        if ! mv "$ZEN_DIR" "$old"; then
            rm -rf "$staging"
            skip "Could not move the existing install aside at $ZEN_DIR"
        fi
    fi
    if ! mv "$staging/zen" "$ZEN_DIR"; then
        [[ -n "$old" ]] && mv "$old" "$ZEN_DIR"
        rm -rf "$staging"
        skip "Could not install the new Zen tree at $ZEN_DIR"
    fi
    rm -rf "$staging"
    [[ -n "$old" ]] && rm -rf "$old"

    zen_write_launcher
    ok_changed "Zen $version installed to $ZEN_DIR"
    ok "Launcher: $ZEN_BIN — menu entry: $ZEN_DESKTOP_FILE"

    # Make zen resolvable in the current session.
    export PATH="$HOME/.local/bin:$PATH"
}
