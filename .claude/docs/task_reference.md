# Task reference

`mise tasks` lists everything; this file says what each one **owns** and when it runs. Tasks are
files under `mise/tasks/`, deployed by linking the whole tree to `~/.config/mise/tasks`.

## Conventions every task follows

```bash
#!/usr/bin/env bash
#MISE description="..."
#MISE raw=true
#USAGE flag "--update" help="..."
set -eo pipefail

# shellcheck disable=SC2034  # consumed by the logging helpers in lib/profile.sh
TASK_NAME="install:example"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib"
source "$LIB/profile.sh"

require_profile example
```

- **`#USAGE flag "--x"` → `$usage_x`** (dashes become underscores), unset when absent, so
  `${usage_x:-false}` is the idiom. Never hand-roll argument parsing.
- **`lib/*.sh` ship mode 644.** An *executable* file under `tasks/lib/` is listed and runnable as
  `lib:name`; a non-executable one is ignored. Tasks themselves are 755.
- **`fail` vs `skip`** — `fail` means "this machine is in a state I refuse to guess about";
  everything environmental uses `skip` (warn + exit 0), because a non-zero task aborts the rest
  of the bootstrap chain.
- **No prompts** in anything the chain runs. `[[ -t 0 ]]` guards the interactive-only tasks.

## `lib/` helpers

| File | Provides |
| --- | --- |
| `profile.sh` | `info`/`warn`/`ok`/`ok_changed`/`fail`/`skip`, `has_profile`/`require_profile`, `have`, `sudo_ok`, `gh_curl`, `REPO`/`CONF` |
| `apt_repo.sh` | vendor repo registry, `apt_repo_write`/`_refresh`/`_ensure_known`, `apt_pkg_missing`/`_install`/`_upgrade`, `apt_add_user_group`, `apt_codename` |
| `obsidian.sh` | Obsidian AppImage fetch/install/desktop-integration |
| `zen.sh` | Zen tarball fetch/install/launcher, shared by `install:zen` and `update:zen` |
| `gpg.sh` | shared helpers for the `gpg:*` suite |
| `cosmic_theme.py` | COSMIC theme picker helper (invoked as `python3 "$HELPER"`) |

`sudo_ok` deserves a note: it returns true when sudo can elevate *here and now*, leaving a cached
timestamp so the caller's own `sudo -n` calls succeed. Gating on `sudo -n` alone would make every
install task permanently inert on a normal desktop account; at a real terminal `sudo -v` asks once.

---

## The bootstrap chain

`[tasks.bootstrap]` in `mise/config.toml`, in order. Every member is a no-op without its profile,
so the list is unconditional.

| # | Task | Owns |
| --- | --- | --- |
| 1 | `setup:custom-hookup` | clones/links the private companion repo, trusts the drop-in, removes it again if the live lint fails |
| 2 | `setup:repo-links` | links into `[bootstrap.repos]` clones (oh-my-tmux's `tmux.conf`, `fpp`) — these cannot be `[dotfiles]` entries |
| 3 | `update:tmux-local` | folds upstream oh-my-tmux template changes into our `tmux.conf.local`; a conflict parks a `.merged` preview instead of breaking anything |
| 4 | `setup:completions` | generates shell completions into `~/.config/completions` |
| 5 | `setup:git-signing` | writes `~/.gitconfig.local` from the companion's example when the GPG key is present; compares key IDs, `--force` to adopt a rotated one |
| 6 | `setup:login-shell-fallback` | the login shell: sudo chsh → sudo usermod → interactive chsh → `exec zsh` in `~/.bash_profile` |
| 7 | `setup:p10k-icon --if-unanswered` | the one interactive step; asks at most once per machine and only at a terminal |
| 8 | `setup:apt-repos` | every active profile's vendor apt repos, one pass, one `apt-get update` |
| 9 | `setup:fonts` | Nerd Font + terminal font (`graphical`) |
| 10 | `install:ghostty` | terminal (`graphical`); `--method appimage\|deb\|source\|snap` |
| 11 | `install:obsidian` | AppImage (`graphical`) |
| 12 | `install:veracrypt` | console `.deb` (`veracrypt`) |
| 13 | `install:gnome-extensions` | extensions + `dconf` restore (`gnome`) |
| 14 | `setup:cosmic` | ddcutil/i2c udev rule and group (`cosmic`) |
| 15 | `install:tailscale` | Tailscale (`tailscale`) — **never runs `tailscale up`** |
| 16 | `install:docker` | Engine, CLI, containerd, buildx/compose (`docker`) + the `docker` group |
| 17 | `install:1password` | desktop app (`1password`); the `op` CLI is a `[tools]` entry |
| 18 | `install:brave` | Brave (`browsers`) |
| 19 | `install:virtualbox` | Oracle's build (`virt`) + `vboxusers` |
| 20 | `install:vagrant` | Vagrant (`virt`) |
| 21 | `install:zen` | Zen browser tarball (`browsers`) — last, it is the largest download |

**Deliberately not chained:** `setup:profiles`, `setup:cosmic-theme`, `setup:cosmic-theme-clean`
and `setup:hostname` (all menus/prompts), `update:gnome-extensions` (writes *and commits* into
another git repo — a bootstrap must never do that unattended), and the other `update:*` tasks.
`setup:profiles` is the sharpest case: it edits the very file that decides which profiles are
active, so running it inside a converge would change the chain's own inputs midway.

---

## Run by hand

| Task | Flags | Notes |
| --- | --- | --- |
| `cleanup` | `--dry-run --yes` | removes symlinks that are **both** dangling **and** into this repo. Does not undo a working deployment |
| `repo:lint` | `--fix` | everything CI runs. Required before any push |
| `setup:hostname` | `--name <n> --show` | validates the label and keeps `/etc/hosts` in sync |
| `setup:p10k-icon` | `--icon --show --clear --if-unanswered` | without the flag it always opens the picker; the flag is what makes the chained call once-only |
| `setup:profiles` | `--list` | the interactive editor for `~/.config/mise/miserc.toml`. `install.sh`'s numbered picker only fires when that file does not yet exist; this is how profiles change on every run after the first. Reads the registry from `install.sh`'s `KNOWN_PROFILES` and the descriptions from `miserc.example.toml`, so a new profile needs no change here. Rewrites only the `env` line, leaving any other setting in the file intact, then offers `mise bootstrap --yes` and runs `cleanup` |
| `setup:cosmic-theme` | | menu |
| `setup:cosmic-theme-clean` | | deletes cached themes |
| `update:repos` | `--check` | updates the clones mise never touches again (the ones with no `ref`) |
| `update:tmux-local` | `--check` | also chained |
| `update:obsidian` | `--check` | installs a newer release; never installs from scratch |
| `update:zen` | `--check` | same; Zen also self-updates, and the version is read from the install's own `application.ini` |
| `update:gnome-extensions` | | refreshes the manifest in the companion repo and commits there |

### The `gpg:*` suite

| Task | Flags |
| --- | --- |
| `gpg:list` | |
| `gpg:check-expiry` | `--strict` |
| `gpg:extend-expiry` | `--period <p> --key <fpr> --yes` |
| `gpg:backup` | encrypted keyring archive |
| `gpg:restore` | `--archive <path> --yes --force-no-backup --skip-ownertrust` |
| `gpg:trust` | `--yes --dry-run --force-no-backup` — sets ownertrust=ultimate on your own keys |

---

## The `--update` convention

Every third-party application installer follows it:

- **not installed** → install, unattended, no flag needed
- **installed and current** → say so, do nothing
- **installed and outdated** → *report* it and exit 0; `--update` is what actually upgrades

For apt-backed apps `--update` means `apt-get update` followed by `apt-get install --only-upgrade`
on that package set only. For the tarball/AppImage apps it means fetch and replace.

The point is that `mise bootstrap` must be safe to run at any moment, and that means never
replacing a running terminal's, browser's, editor's or VPN daemon's binary without being asked.

---

## Adding a task

1. Create `mise/tasks/<group>/<name>`, `chmod +x`, with the header conventions above.
2. Gate it: `require_profile <p>` if it belongs to a profile.
3. Use `skip` for anything environmental. Assume it runs unattended, with no terminal.
4. If it belongs in the chain, add `{ task = "..." }` to `[tasks.bootstrap].run` **in the right
   band** — essential early, optional late.
5. `mise run repo:lint` before committing.

Never port an old `#MISE depends=[...]` header verbatim: one naming a task that no longer exists
fails with `ERROR task not found`, rc=1, which aborts the chain exactly like any other failure.
