# shellcheck shell=bash
# Shared helpers for the gpg:* tasks. Ported near-verbatim from the old repo's
# lib/gpg_helpers.sh; the only structural change is the base — these source
# lib/profile.sh (info/warn/ok/ok_changed/fail/skip/have) instead of the old
# repo's lib/helpers.sh, which does not exist here.
#
# Source AFTER lib/profile.sh.
#
# None of these pass --homedir: they operate on the ambient keyring, i.e.
# $GNUPGHOME or ~/.gnupg. That is deliberate (they are user-facing maintenance
# commands, not deployment steps) and it is also how they are tested safely —
# point GNUPGHOME at a throwaway directory and run `gpgconf --kill gpg-agent`
# between runs.

# Warn threshold in days for "expiring soon".
: "${GPG_EXPIRY_WARN_DAYS:=30}"

require_gpg() {
    have gpg || fail "gpg not found in PATH — install gnupg (apt install gnupg) and retry"
}

# Field separator for secret_keys_stream output. ASCII Unit Separator (0x1F) —
# non-whitespace, so `read` preserves empty fields (unlike tab/space).
GPG_FS=$'\x1f'

# Emit rows describing every own secret key and subkey, one per line, with
# fields separated by $GPG_FS.
# Columns: type  primary_fpr  own_fpr  uid  expires_epoch  caps
#   type: "pri" for a primary key row, "sub" for a subkey row
#   uid is empty on "sub" rows (it belongs to the primary)
#   expires_epoch is empty when the key has no expiration
secret_keys_stream() {
    gpg --list-secret-keys --with-colons --fixed-list-mode 2>/dev/null \
        | awk -F: -v FS_OUT="$GPG_FS" '
        function emit_primary() {
            if (pri_fpr != "" && !pri_emitted) {
                printf "pri%s%s%s%s%s%s%s%s%s\n", FS_OUT, pri_fpr, FS_OUT, pri_fpr, FS_OUT, pri_uid, FS_OUT, pri_exp, FS_OUT pri_caps
                pri_emitted = 1
            }
        }
        $1 == "sec" {
            emit_primary()
            pri_exp = $7; pri_caps = $12
            pri_fpr = ""; pri_uid = ""; pri_emitted = 0
            state = "need_pri_fpr"
            next
        }
        $1 == "fpr" && state == "need_pri_fpr" {
            pri_fpr = $10
            state = "have_pri_fpr"
            next
        }
        $1 == "uid" && state == "have_pri_fpr" && pri_uid == "" {
            pri_uid = $10
            emit_primary()
            next
        }
        $1 == "ssb" {
            emit_primary()
            sub_exp = $7; sub_caps = $12
            state = "need_sub_fpr"
            next
        }
        $1 == "fpr" && state == "need_sub_fpr" {
            printf "sub%s%s%s%s%s%s%s%s%s\n", FS_OUT, pri_fpr, FS_OUT, $10, FS_OUT, "", FS_OUT, sub_exp, FS_OUT sub_caps
            state = ""
            next
        }
        END { emit_primary() }
    '
}

# Distinct primary fingerprints, one per line.
primary_fprs() {
    secret_keys_stream | awk -F"$GPG_FS" '$1 == "pri" { print $2 }'
}

# Short fingerprint: last 16 hex chars.
short_fpr() { printf '%s' "${1: -16}"; }

# UTC date string for an epoch, or "never" if empty.
format_date() {
    local epoch="$1"
    if [[ -z "$epoch" ]]; then
        printf 'never'
    else
        date -u -d "@$epoch" +%Y-%m-%d
    fi
}

# Days between now and the given epoch. Empty epoch → empty output.
days_remaining() {
    local epoch="$1"
    [[ -z "$epoch" ]] && return 0
    local now
    now="$(date +%s)"
    printf '%d' "$(((epoch - now) / 86400))"
}

# Classify: none | ok | warn | expired.
expiry_state() {
    local days="$1"
    if [[ -z "$days" ]]; then
        printf 'none'
    elif ((days < 0)); then
        printf 'expired'
    elif ((days <= GPG_EXPIRY_WARN_DAYS)); then
        printf 'warn'
    else
        printf 'ok'
    fi
}

# Wrap text with the ANSI color matching an expiry state.
colorize_expiry() {
    local state="$1" text="$2"
    case "$state" in
        ok) printf '\033[32m%s\033[0m' "$text" ;;
        warn) printf '\033[33m%s\033[0m' "$text" ;;
        expired) printf '\033[1;31m%s\033[0m' "$text" ;;
        *) printf '%s' "$text" ;;
    esac
}

# Truncate a string to N chars, appending ellipsis if cut.
truncate_str() {
    local s="$1" n="$2"
    if ((${#s} > n)); then
        printf '%s…' "${s:0:n-1}"
    else
        printf '%s' "$s"
    fi
}

# Print the table header used by `gpg:check-expiry` and `gpg:list`.
print_expiry_header() {
    local show_caps="${1:-0}"
    if ((show_caps)); then
        printf '  %-4s %-16s %-40s %-10s %-8s %s\n' \
            "Type" "Fingerprint" "UID" "Expires" "Days" "Caps"
    else
        printf '  %-4s %-16s %-40s %-10s %s\n' \
            "Type" "Fingerprint" "UID" "Expires" "Days"
    fi
}

# Print one table row from a line produced by secret_keys_stream.
# Args: <line> [show_caps=0]
print_expiry_row() {
    local line="$1" show_caps="${2:-0}"
    local type pri_fpr own_fpr uid epoch caps
    # shellcheck disable=SC2034  # pri_fpr is a positional placeholder: the row format
    # puts it before the field we print, so it has to be named to be skipped.
    IFS="$GPG_FS" read -r type pri_fpr own_fpr uid epoch caps <<<"$line"

    local days state days_str date_str uid_disp caps_disp
    days="$(days_remaining "$epoch")"
    state="$(expiry_state "$days")"
    date_str="$(format_date "$epoch")"
    if [[ -z "$days" ]]; then
        days_str="—"
    else
        days_str="$days"
    fi

    if [[ "$type" == "pri" ]]; then
        uid_disp="$(truncate_str "$uid" 40)"
    else
        uid_disp="(subkey)"
    fi
    caps_disp="$caps"

    # Colorize the days cell only; leave the rest uncolored so columns stay aligned.
    local days_cell
    days_cell="$(colorize_expiry "$state" "$(printf '%-8s' "$days_str")")"

    if ((show_caps)); then
        printf '  %-4s %-16s %-40s %-10s %s %s\n' \
            "$type" "$(short_fpr "$own_fpr")" "$uid_disp" "$date_str" "$days_cell" "$caps_disp"
    else
        printf '  %-4s %-16s %-40s %-10s %s\n' \
            "$type" "$(short_fpr "$own_fpr")" "$uid_disp" "$date_str" "$days_cell"
    fi
}

# ─── Keyring safety net ───────────────────────────────────────────────────────
#
# Anything that imports into the keyring gets one of these first. gpg's own
# --import is additive, but --import-ownertrust OVERWRITES the trust of every
# key named in the file, and a corrupt archive can abort a restore half-done.
# A tarball of the whole keyring directory is the only cheap way back.
#
# Echoes the backup path on success; returns non-zero (with a warning) if the
# keyring could not be archived.
# It is deliberately NOT encrypted, unlike gpg:backup's output: this is a
# same-disk copy of a directory that already sits there unencrypted, taken
# mid-restore, and needing a passphrase to roll back a failed restore is how
# people lose keyrings. It is created 0600 (the directory it copies is 0700)
# and the old ones are pruned below so they do not accumulate forever.
backup_keyring() {
    local home_dir out
    home_dir="${GNUPGHOME:-$HOME/.gnupg}"
    if [[ ! -d "$home_dir" ]]; then
        return 0 # nothing to lose yet
    fi
    out="${home_dir%/}.pre-restore-$(date -u +%Y%m%dT%H%M%SZ).tar"
    # Create it 0600 BEFORE tar writes a byte: `tar` then `chmod` leaves the
    # whole keyring readable at the process umask for the duration of the write.
    (umask 077 && : >"$out") 2>/dev/null || return 1
    if tar -cf "$out" -C "$(dirname "$home_dir")" "$(basename "$home_dir")" 2>/dev/null; then
        chmod 600 "$out"
        # Keep the three most recent; every restore makes one and nothing else
        # ever removed them.
        local old
        while IFS= read -r old; do
            rm -f "$old"
        done < <(find "$(dirname "$home_dir")" -maxdepth 1 -type f \
            -name "$(basename "${home_dir%/}").pre-restore-*.tar" 2>/dev/null \
            | sort -r | tail -n +4)
        printf '%s' "$out"
        return 0
    fi
    rm -f "$out"
    return 1
}

# confirm_critical <prompt> — like confirm(), but --yes does NOT answer it.
#
# The distinction matters exactly once: when the pre-import keyring archive
# FAILED and the next step is --import-ownertrust, which overwrites the trust
# level of every key in the archive and cannot be undone without that backup.
# `--yes` is documented, and understood, as "skip the confirmations"; letting
# it also wave through "there is no way back from here" turns a full disk into
# silent, unrecoverable trust loss. That one needs its own opt-in.
confirm_critical() {
    if [[ "${FORCE_NO_BACKUP:-false}" == "true" ]]; then
        warn "--force-no-backup given: proceeding with no way back"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "No terminal to confirm at, and --force-no-backup was not given — declining: $1"
        return 1
    fi
    local reply
    printf '%s (y/N): ' "$1"
    read -r reply || reply=""
    [[ "$reply" =~ ^[Yy]$ ]]
}

# confirm <prompt> — true when the user agrees. Honours --yes via $ASSUME_YES,
# and refuses (rather than hanging) when there is no terminal to ask at.
confirm() {
    if [[ "${ASSUME_YES:-false}" == "true" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "No terminal to confirm at, and --yes was not given — declining: $1"
        return 1
    fi
    local reply
    printf '%s (y/N): ' "$1"
    read -r reply || reply=""
    [[ "$reply" =~ ^[Yy]$ ]]
}
