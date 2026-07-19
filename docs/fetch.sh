#!/usr/bin/env bash
# Refresh the vendored mise documentation snapshot in docs/upstream/.
# These files are gitignored — run this script after cloning (or on a mise
# version bump) to have the upstream reference available locally.
set -euo pipefail

BASE="https://raw.githubusercontent.com/jdx/mise/main/docs"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/upstream"

FILES=(
    bootstrap.md
    dotfiles.md
    configuration.md
    configuration/environments.md
    configuration/settings.md
    templates.md
    tasks/task-configuration.md
    bootstrap/repos.md
    bootstrap/shell.md
    bootstrap/systemd.md
    bootstrap/user.md
    bootstrap/launchd.md
    bootstrap/macos-defaults.md
    bootstrap/packages/index.md
    bootstrap/packages/apt.md
    bootstrap/packages/apk.md
    bootstrap/packages/dnf.md
    bootstrap/packages/pacman.md
    bootstrap/packages/brew.md
    bootstrap/packages/flatpak.md
    bootstrap/packages/mas.md
    bootstrap/packages/plugins.md
)

for f in "${FILES[@]}"; do
    mkdir -p "$DEST/$(dirname "$f")"
    if curl -sfL "$BASE/$f" -o "$DEST/$f"; then
        echo "OK   $f"
    else
        echo "FAIL $f" >&2
    fi
done
