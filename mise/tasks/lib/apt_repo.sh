# shellcheck shell=bash
# Third-party apt repository helpers, shared by setup:apt-repos and the
# install:* tasks that need a vendor repo. Source AFTER lib/profile.sh — it
# needs info/warn/ok/ok_changed/skip/have/sudo_ok.
#
# Why this exists at all: mise's apt manager installs packages from repos that
# are ALREADY configured; it never adds a repo or a key (bootstrap/packages/
# apt.md). And a `[bootstrap.packages]` entry naming a package apt cannot find
# does not merely skip — mise batches every apt package into ONE `apt-get
# install`, so one unresolvable name fails the whole packages step and
# [tasks.bootstrap] never runs (verified in a sandbox: with a bogus entry
# added, zsh/git/curl were in the same failing command and the task chain did
# not execute). Vendor apps therefore live in tasks, where `skip` keeps a bad
# day local.
#
# ─── Call contract (read this before using the functions) ────────────────────
#
# Every task here runs under `set -eo pipefail`. These functions are written so
# that no internal command can trip errexit: each fallible call is guarded, and
# failure is reported through the RETURN CODE. Callers must therefore always
# consume that code — `apt_repo_ensure_known docker || skip "..."` — and never
# call one bare. A bare call that returned non-zero would exit the task, and a
# non-zero task aborts the rest of the [tasks.bootstrap] chain.

# ─── Repo registry ────────────────────────────────────────────────────────────
#
# One place for all six vendor repos, so setup:apt-repos (which adds every
# active profile's repos in one pass) and the individual install tasks (which
# must also work when run by hand) cannot drift apart.
#
# Fields, "|"-separated: keyring|key_url|uris|suites|components|architectures
#
#   keyring        BASENAME of the keyring in /usr/share/keyrings. Use the
#                  VENDOR'S canonical name, not a generated one. This is not
#                  cosmetic: brave-keyring's postinst greps the sources file for
#                  `Signed-By: /usr/share/keyrings/brave-browser-archive-keyring.gpg`
#                  and, when it doesn't match, symlinks the key into
#                  /etc/apt/trusted.gpg.d/ — where it is trusted for EVERY repo
#                  on the machine, the exact thing signed-by exists to prevent.
#   suites         @CODENAME@ is replaced with apt_codename() at use time.
#   architectures  empty = no Architectures field (all).
declare -A APT_REPOS=(
    [tailscale]="tailscale-archive-keyring.gpg|https://pkgs.tailscale.com/stable/ubuntu/@CODENAME@.noarmor.gpg|https://pkgs.tailscale.com/stable/ubuntu|@CODENAME@|main|"
    [docker]="docker-archive-keyring.gpg|https://download.docker.com/linux/ubuntu/gpg|https://download.docker.com/linux/ubuntu|@CODENAME@|stable|amd64 arm64"
    [1password]="1password-archive-keyring.gpg|https://downloads.1password.com/linux/keys/1password.asc|https://downloads.1password.com/linux/debian/amd64|stable|main|amd64"
    [brave]="brave-browser-archive-keyring.gpg|https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg|https://brave-browser-apt-release.s3.brave.com|stable|main|amd64 arm64"
    [virtualbox]="oracle-virtualbox-2016.gpg|https://www.virtualbox.org/download/oracle_vbox_2016.asc|https://download.virtualbox.org/virtualbox/debian|@CODENAME@|contrib|amd64"
    [vagrant]="hashicorp-archive-keyring.gpg|https://apt.releases.hashicorp.com/gpg|https://apt.releases.hashicorp.com|@CODENAME@|main|amd64"
)

# Set to 1 by apt_repo_write when it actually writes something; consumed and
# reset by apt_repo_refresh.
# shellcheck disable=SC2034  # part of this lib's API, read by sourcing tasks
APT_REPO_CHANGED=0

# ─── Distro identity ──────────────────────────────────────────────────────────

# apt_codename — the Ubuntu codename a vendor repo is keyed by.
#
# UBUNTU_CODENAME first, VERSION_CODENAME only as a fallback. On Mint — which
# README.md lists as a target — VERSION_CODENAME is the Mint release name
# ("xia", "wilma") while UBUNTU_CODENAME is the Ubuntu base ("noble"), and the
# vendors only publish the latter:
#   https://pkgs.tailscale.com/stable/ubuntu/xia.noarmor.gpg    -> 404
#   https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg  -> 200
# This machine (Pop!_OS) sets both to "noble", so the bug is invisible here.
apt_codename() {
    local codename=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        codename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
    fi
    [[ -n "$codename" ]] || return 1
    printf '%s' "$codename"
}

# ─── Enabled-repo detection ───────────────────────────────────────────────────

# apt_repo_enabled <uri> — true when apt is ALREADY fetching packages from this
# URI, whatever file or format declares it.
#
# This deliberately does not grep /etc/apt/sources.list.d. That directory is
# not a list of active repos: on this machine it holds 1password.save (a
# COMMENTED-OUT deb line still containing the 1Password URI),
# nala-sources.list.disabled, and three *.sources.save files — none of which
# apt reads. A grep for the URI matches all of them, concludes "already
# configured", writes nothing, and the subsequent `apt-get install 1password`
# then fails "Unable to locate package" forever. It also cannot tell .list from
# .sources, so it would happily add a duplicate of a repo declared in the other
# format (apt then warns about a doubly-configured target).
#
# `apt-get indextargets` is apt's own view of its ENABLED sources, so it is
# immune to all of that.
apt_repo_enabled() {
    local uri="${1%/}" line
    have apt-get || return 1
    while IFS= read -r line; do
        [[ "${line%/}" == "Repo-URI: $uri" ]] && return 0
    done < <(apt-get indextargets --no-release-info 'Created-By: Packages' 2>/dev/null \
        | grep '^Repo-URI:' || true)
    return 1
}

# ─── Writing a repo ───────────────────────────────────────────────────────────

# apt_repo_install_key <key_url> <keyring_basename>
#
# Handles both encodings vendors publish — verified byte-wise: Brave's and
# Tailscale's .noarmor.gpg are BINARY, while Docker's, HashiCorp's, Oracle's
# and 1Password's are ASCII-armored. Dearmoring a binary key fails, and
# installing an armored key as-is gives apt a keyring it cannot read.
apt_repo_install_key() {
    local key_url="$1" keyring="$2" dest="/usr/share/keyrings/$2" tmp rc=0

    tmp="$(mktemp)" || return 1
    if ! curl -fsSL -o "$tmp" "$key_url"; then
        rm -f "$tmp"
        warn "Could not download the signing key: $key_url"
        return 1
    fi

    if head -c 64 "$tmp" | grep -q 'BEGIN PGP PUBLIC KEY BLOCK'; then
        local armored="$tmp.armored"
        mv "$tmp" "$armored" || {
            rm -f "$tmp"
            return 1
        }
        if ! gpg --batch --yes --dearmor --output "$tmp" "$armored" 2>/dev/null; then
            rm -f "$tmp" "$armored"
            warn "Could not dearmor the signing key from $key_url"
            return 1
        fi
        rm -f "$armored"
    fi

    # Verified, not trusted: a captive portal or an error page returns 200 with
    # a body, and an unreadable keyring makes every later apt run warn instead
    # of failing loudly.
    if ! gpg --batch --show-keys "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        warn "The file at $key_url is not a valid GPG key (captive portal? error page?)"
        return 1
    fi

    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 0
    fi

    if ! sudo -n install -m 0644 -o root -g root "$tmp" "$dest"; then
        rm -f "$tmp"
        warn "Could not install the keyring at $dest"
        rc=1
    else
        ok_changed "Installed the signing keyring: $keyring"
    fi
    rm -f "$tmp"
    return $rc
}

# apt_repo_write <slug> — add the registry repo <slug> if it is not already
# enabled. Does NOT refresh apt metadata; call apt_repo_refresh afterwards.
# Returns 0 when the repo is present (already, or newly written).
apt_repo_write() {
    local slug="$1" spec keyring key_url uris suites components arches codename
    spec="${APT_REPOS[$slug]:-}"
    [[ -n "$spec" ]] || {
        warn "No apt repo registered for '$slug'"
        return 1
    }

    IFS='|' read -r keyring key_url uris suites components arches <<<"$spec"

    if [[ "$key_url$suites" == *"@CODENAME@"* ]]; then
        codename="$(apt_codename)" || {
            warn "Could not determine the Ubuntu codename from /etc/os-release"
            return 1
        }
        key_url="${key_url//@CODENAME@/$codename}"
        suites="${suites//@CODENAME@/$codename}"
    fi

    if apt_repo_enabled "$uris"; then
        ok "apt repo already enabled: $slug"
        return 0
    fi

    have curl gpg || {
        warn "curl and gpg are required to add the $slug repo"
        return 1
    }
    sudo_ok || {
        warn "Adding the $slug apt repo needs root, and sudo cannot ask for a password here"
        return 1
    }

    apt_repo_install_key "$key_url" "$keyring" || return 1

    # deb822. It is the format Docker, 1Password and Brave already use here,
    # and writing it up front means 1password.postinst — which migrates a
    # .list to .sources and comments the old one out — has nothing to change.
    local sources="/etc/apt/sources.list.d/$slug.sources" tmp
    tmp="$(mktemp)" || return 1
    {
        printf 'Types: deb\n'
        printf 'URIs: %s\n' "$uris"
        printf 'Suites: %s\n' "$suites"
        printf 'Components: %s\n' "$components"
        [[ -n "$arches" ]] && printf 'Architectures: %s\n' "$arches"
        printf 'Signed-By: /usr/share/keyrings/%s\n' "$keyring"
    } >"$tmp"

    if ! sudo -n install -m 0644 -o root -g root "$tmp" "$sources"; then
        rm -f "$tmp"
        warn "Could not write $sources"
        return 1
    fi
    rm -f "$tmp"
    ok_changed "Added the $slug apt repo -> $sources"
    APT_REPO_CHANGED=1
    return 0
}

# apt_repo_refresh — one `apt-get update`, and only if a repo was written.
# Batching is the point: setup:apt-repos writes every active profile's repo and
# calls this once, so a fresh machine pays for one refresh instead of six.
apt_repo_refresh() {
    [[ "$APT_REPO_CHANGED" == "1" ]] || return 0
    sudo_ok || {
        warn "apt-get update needs root, and sudo cannot ask for a password here"
        return 1
    }
    info "Refreshing apt metadata ..."
    if ! sudo -n apt-get update; then
        warn "apt-get update failed — a newly added repo may be unreachable"
        return 1
    fi
    APT_REPO_CHANGED=0
    return 0
}

# apt_repo_ensure_known <slug> — write + refresh, for a task run on its own.
# In the bootstrap chain setup:apt-repos has normally done this already, so
# this is a no-op that costs one `apt-get indextargets`.
apt_repo_ensure_known() {
    apt_repo_write "$1" || return 1
    apt_repo_refresh || return 1
    return 0
}

# ─── Installing packages ──────────────────────────────────────────────────────

# apt_pkg_missing <pkg...> — echo the subset that dpkg does not have installed,
# one per line, and NOTHING AT ALL when everything is installed.
#
# That last part is the whole reason this has a guard: `printf '%s\n'` with an
# empty array still prints one empty line, so `mapfile -t MISSING < <(...)`
# came back as a 1-element array containing "". Every caller then believed a
# package named "" was missing, skipped its "already installed" branch — taking
# the --update gate with it — and ran `apt-get install ""`.
apt_pkg_missing() {
    local pkg state missing=()
    for pkg in "$@"; do
        state="$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)"
        [[ "$state" == "installed" ]] || missing+=("$pkg")
    done
    [[ ${#missing[@]} -gt 0 ]] || return 0
    printf '%s\n' "${missing[@]}"
}

# apt_pkg_install <pkg...> — install the given packages.
#
# --no-remove is not optional here. `docker-ce` declares `Conflicts: docker.io`
# with NO matching `Replaces:`, so apt's -y resolver satisfies the conflict by
# REMOVING docker.io — silently deleting a package the user installed by hand.
# With --no-remove apt refuses the transaction instead, and the caller reports
# what is in the way.
apt_pkg_install() {
    have apt-get || {
        warn "apt-get not found"
        return 1
    }
    sudo_ok || {
        warn "Installing packages needs root, and sudo cannot ask for a password here"
        return 1
    }
    if ! sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove "$@"; then
        warn "apt-get install failed for: $*"
        return 1
    fi
    return 0
}

# apt_pkg_upgrade <pkg...> — refresh metadata and upgrade only these packages,
# never pulling in anything new (`--only-upgrade`).
apt_pkg_upgrade() {
    sudo_ok || {
        warn "Upgrading packages needs root, and sudo cannot ask for a password here"
        return 1
    }
    sudo -n apt-get update || warn "apt-get update failed — upgrading against stale metadata"
    if ! sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade --no-remove "$@"; then
        warn "apt-get could not upgrade: $*"
        return 1
    fi
    return 0
}

# ─── Group membership ─────────────────────────────────────────────────────────

# apt_add_user_group <group> — add $USER to <group> when the group exists and
# the user isn't in it. Same shape as setup:cosmic's i2c handling.
#
# Callers must say what the group grants: `docker` is effectively root (any
# member can start a container that mounts /), and `vboxusers` grants raw USB
# device access.
apt_add_user_group() {
    local group="$1"
    getent group "$group" >/dev/null 2>&1 || {
        warn "No '$group' group on this system — skipping group membership"
        return 0
    }
    if id -nG "$USER" 2>/dev/null | grep -qw "$group"; then
        ok "$USER is already in the '$group' group"
        return 0
    fi
    sudo_ok || {
        warn "Adding $USER to '$group' needs root — run by hand: sudo usermod -aG $group $USER"
        return 0
    }
    if ! sudo -n usermod -aG "$group" "$USER"; then
        warn "Could not add $USER to the '$group' group"
        return 0
    fi
    ok_changed "Added $USER to the '$group' group (log out and back in for it to take effect)"
    return 0
}
