# Troubleshooting

Failure modes real machines have hit, and the ones the design anticipates. Several look like
"nothing happened", which is the hardest class — mise is quiet about more than you would expect.

---

## The bootstrap stops early

### `repos: ~/x has local changes; commit, stash, or clean them before bootstrap`

Any **untracked, non-gitignored** file in any `[bootstrap.repos]` clone aborts the whole
bootstrap at step 3 — before `[dotfiles]`, tools and the entire task chain. One file in one clone
is enough.

Gitignored files are fine, which makes the cheapest fix local to the clone and needing no
upstream change:

```bash
printf '<name>\n' >> <clone>/.git/info/exclude
```

This is not hypothetical: shell completions generated into `~/.oh-my-zsh/completions/` did exactly
this. `install.sh` pre-flights `mise bootstrap repos status --json` and refuses with the paths and
the remedies; `mise run update:repos` reports the same set.

### `sudo requires a password but no TTY is available`

Bootstrap step 0 (`accounts`) or step 3 (`files`) has a pending change that needs root, and mise
cannot ask for a password: no controlling terminal *and* no passwordless sudo. It prints the exact
command it wanted to run and **exits 1, skipping every later step** — dotfiles, tools and the whole
imperative tail. `system_packages.sudo = false` does not soften this; it fails the same way with a
different message.

On this repo, only the `cosmic` profile declares anything privileged (the ddcutil udev rule and the
`i2c` group). Three ways out, in order of preference:

```bash
mise bootstrap --yes                      # from a real terminal: sudo prompts once, done
mise bootstrap --skip accounts,files      # converge everything else now, privileged bits later
sudo mise --no-config --no-env --no-hooks bootstrap __apply-system-plan   # what mise printed
```

The last one is mise's own escape hatch and is what the error message hands you. Once the rule and
the group are in place the steps report `unchanged` and never ask for sudo again.

### A clone with a `ref` fails to fast-forward

`ref = "<branch>"` means **mise** fast-forwards it on every apply. If you have committed to that
branch locally, the fast-forward fails and aborts the bootstrap. A fork you commit to is a latent
whole-machine failure — either push it, or drop the `ref`.

It also happens with **no local commits at all**, when upstream rewrites the branch: the clone
then holds the pre-rewrite lineage and reads as ahead-and-behind. `~/.tmux` did exactly this
(ahead 95, behind 119, oh-my-tmux having rebased `master`). `mise run update:repos --check`
reports it as `DIVERGED` with the `git log` to inspect. Confirm the "ahead" commits are not yours
before discarding them:

```bash
git -C ~/.tmux log --format='%an' origin/master..HEAD | sort -u    # any name that is not upstream's?
git -C ~/.tmux status --porcelain                                  # must be empty
git -C ~/.tmux branch pre-reset-$(date +%F)                        # a way back
git -C ~/.tmux reset --hard origin/master
```

### `files: sources do not exist`

A `[dotfiles]` entry with an **explicit** `source` that isn't there aborts the *entire* apply.
Nothing deploys — not the other thirty entries, not `.zshrc`.

Usually this means an entry points at something a later bootstrap step creates. Those links belong
in `setup:repo-links`, where a missing clone is only a warning. `python3 scripts/lint-config.py`
catches it before you push.

### `failed to locate Git repository for ~/.dotfiles-mise/home/.claude/commands`

The four `symlink-each` entries carry `manifest = "git"`, so mise resolves them with `git ls-files`
before applying anything. If that command fails, the *whole* apply aborts and nothing deploys —
`~/.zshrc` included. Two causes:

- **The repo is not a git work tree.** A tarball or a `cp` that dropped `.git`. Re-clone; the
  documented install path is `git clone`.
- **`git` itself refuses to start.** Almost always a corrupt `~/.gitconfig`:
  `fatal: bad config line 1 in file /home/<user>/.gitconfig`. Since `~/.gitconfig` is a symlink
  into the repo, the damaged file is usually `home/.gitconfig` in the working tree — and git will
  not run the command that fixes it until you take the broken config out of the picture:

  ```bash
  GIT_CONFIG_GLOBAL=/dev/null git -C ~/.dotfiles-mise checkout -- home/.gitconfig
  mise bootstrap dotfiles apply
  ```

  A `>` redirect into any deployed target does this, `sandbox/mkhome.sh`'s fake `$HOME` included:
  every target in there is a symlink into the real working tree.

### A task in the chain failed and everything after it was skipped

By design: a non-zero `{ task = "x" }` member aborts every later member. Find the first failure,
not the last. If the cause is environmental (no network, no sudo, no desktop session), the task
should have used `skip` — that is a bug in the task, and worth fixing rather than working around.

### `ERROR task not found`

A stale `#MISE depends=[...]` naming a task that no longer exists. Fails with rc=1 and aborts the
chain like any other failure.

### The bootstrap "succeeded" but the login shell is unchanged

Expected on an unattended run. `setup:login-shell-fallback` tries sudo chsh → sudo usermod →
interactive chsh → `exec zsh` in `~/.bash_profile`, and lands on whichever rung works. Bare `chsh`
PAM-prompts, so it cannot succeed without a terminal.

This repo declares no `[bootstrap.user]` section on purpose: that step runs exactly one
PAM-prompting `chsh`, it runs *before* the task step, and its failure would take the whole chain
with it — including the fallback task written for this case.

---

## Something silently isn't applying

### A profile's settings stopped working after a rename

Removing a `[dotfiles]` entry or renaming a `config.<profile>.toml` leaves a dangling symlink.
`mise config ls`, `mise bootstrap dotfiles status` and `mise doctor` all stay quiet about it while
the profile silently stops applying.

```bash
mise run cleanup --dry-run
```

### A `conf.d/` drop-in has no effect

On mise 2026.7.x an **untrusted** drop-in was *silently ignored* — status exit 0, no trust
message, entries simply absent. On 2026.9.15 a never-trusted drop-in in the global `conf.d`
loads in full, so trust is no longer the likely cause — unless it was explicitly **ignored**
(`mise trust --ignore`), which hides it the same silent way:

```bash
mise config ls                                   # is it listed at all?
mise trust ~/.config/mise/conf.d/50-custom.toml  # un-ignore / trust it
```

Otherwise check the link resolves (`ls -lL`) and that `lint-config.py --live` passes —
`setup:custom-hookup` removes the link when it does not.

### A `[dotfiles]` entry never deploys and nothing complains

An entry with **no source** (mirroring `dotfiles.root`) whose file is missing is silently ignored:
it never deploys, never appears in `mise bootstrap dotfiles status`, and `--missing` still exits 0.
A typo'd target is invisible forever with every check green. `lint-config.py` stats every source
precisely because mise won't.

### Deselecting a profile left its files behind

`cleanup` won't help — the sources still exist, so the links aren't dangling. mise ≥ 2026.9.13
can remove them, because the profile's config file is still on disk and linked:

```bash
mise bootstrap unapply --dry-run <profile>   # the exact rm/rmdir list
mise bootstrap unapply <profile>
```

`setup:profiles` offers this for the profiles you remove. Pass only profiles that are **no longer
selected** — unapply removes an env's resources even while the env is active (the next bootstrap
puts them back). Targets changed since they were applied are kept unless you add `--force`;
packages and tools are out of scope (the output says how to prune packages).

### An entry was deleted from the config and its files are still there

`mise bootstrap dotfiles unapply` reads the **live** config, so once the entry is gone there is
nothing left to unapply: the next apply says "no dotfiles configured" and every link stays. They
are not dangling either — the sources still exist — so `mise run cleanup` skips them by design.

The order that works is `mise bootstrap dotfiles unapply <target>` **first** (`--dry-run` prints
the exact `rm`/`rmdir` list), *then* delete the entry. To fix one after the fact: restore the
entry, unapply, delete it again — or remove the links by hand. Deleting a *source file* needs none
of this: mise records `symlink-each` links under `$MISE_STATE_DIR/dotfiles` and prunes the leftover
on the next apply.

### `mise config ls` shows fewer files than expected

If `MISE_GLOBAL_CONFIG_FILE` is set, mise loads *only* that file on a fresh machine — profile
files, `conf.d/*.toml` and `config.local.toml` are all invisible. Check both with and without it;
they answer different questions.

---

## Files got clobbered

### A real file was replaced with no warning

`mode = "template"` **destroys a pre-existing real file silently** — no error, no backup.
`mode = "symlink"` in the same position refuses. Template mode also replaces a symlink without
comment.

`install.sh` moves conflicting targets aside to `<file>.pre-mise.bak` before the first apply. If
you got here anyway, that backup is where to look.

### mise suggested `--force` / `--force-dotfiles`

**Never run it.** On the self-management entries it overwrites the committed `mise/config*.toml`
with self-referential symlink loops and silently drops the global config. Resolve conflicts by
moving the offending file aside.

### `git config --global` wrote into the repo

`~/.gitconfig` is a symlink into this repo, and `git config --global` follows symlinks. The
`[include]` for `~/.gitconfig.identity` does not save you — includes redirect config *reads*,
never *writes*. Identity goes in `~/.gitconfig.identity` (companion repo), signing in
`~/.gitconfig.local`, and anything shared by every machine is an edit to `home/.gitconfig` that
you commit.

To recover: `git -C ~/.dotfiles-mise checkout home/.gitconfig`.

---

## Fresh-machine installs

### `E: Unable to locate package nala` / `has no installation candidate`

apt's package lists are stale or incomplete. Up to 2026.9.14 mise refreshed them only when
there were none at all, and a freshly installed desktop's stale ones failed the whole packages
step (behaviour #37). **2026.9.15 fixed it**: mise simulates the install first and runs
`apt-get update` once if the simulation fails — measured in a container with the universe lists
deleted. `install.sh` requires 9.15, so on this repo the error now means the package really is
unavailable (a typo, a repo that is not configured, a release that dropped it) — or an older
mise on `PATH`:

```bash
mise --version            # ≥ 2026.9.15? `mise doctor project` checks this too
apt-cache policy <pkg>    # is there a candidate at all?
```

One case 9.15 does not cover: stale lists **plus** a broken third-party source (a vendor repo a
task added, since moved or re-keyed). mise's own refresh then fails on that source —
`apt-get exited with non-zero status: exit code 100` after `Failed to fetch …` — and it aborts.
apt itself refreshes the healthy sources regardless, so:

```bash
sudo apt-get update; mise bootstrap --yes     # `;`, not `&&`: update exits 100 here
```

and fix or remove the broken `/etc/apt/sources.list.d/` file (behaviour #37).

Not `mise bootstrap --update` as a fix: besides the lists, it pulls every unpinned clone.

### Cloning dies with `RPC failed; curl 56 GnuTLS recv error (-24)`

apt's git is linked against `libcurl-gnutls`, which truncates large packs over HTTP/2 on some
networks. `[bootstrap.repos]` clones at step 3 with whatever git is on `PATH` — on a fresh
machine, apt's — while the OpenSSL-linked `conda:git` is a `[tools]` entry installed much later.

`install.sh` detects the linkage and exports an `http.version=HTTP/1.1` override for the run. By
hand:

```bash
git -c http.version=HTTP/1.1 clone ...
```

### `mise install` is rate-limited or crawling

Unlikely since 2026.9.14: version, release and attestation lookups for `github:`/`aqua:` tools go
through mise-versions.jdx.dev, not api.github.com. Measured with no token anywhere, every tool
this repo declares resolved with 4 GitHub API requests (neofetch and resvg fall back to it), and
installing the non-registry set added 2 — against the 60/hour unauthenticated budget. What
still hits the API directly: private repos, a mise-versions failure other than a 404, and this
repo's own tasks that `curl` GitHub (`gh_curl` in `lib/profile.sh` — fonts, ghostty, obsidian,
veracrypt, zen). For those, export `GITHUB_TOKEN` / `MISE_GITHUB_TOKEN` or log `gh` in;
`install.sh` passes on the first of `$MISE_GITHUB_TOKEN` → `$GITHUB_TOKEN` → `$GH_TOKEN` →
`gh auth token` it finds.

Do **not** try to `mise exec`-install `gh` to get one: `mise exec TOOL@latest` is a "fast command"
hard-capped at 3 seconds regardless of `MISE_FETCH_REMOTE_VERSIONS_TIMEOUT`. Also, `mise settings
get <key>` echoes the raw env value unchanged — it never confirms a value parses or applies, so
don't use it as verification.

### `version 'GLIBC_2.39' not found` building treesitter parsers

The `neovim` profile's prebuilt `tree-sitter` carries a glibc floor that tracks its build runner,
and only one glibc asset ships. Ubuntu 22.04 has 2.35. Pin an older release in
`mise/config.neovim.toml`:

```toml
tree-sitter = "0.25.10"   # floor 2.34
```

Measured floors: `0.26.11 = 2.39`, `0.25.10 = 2.34`, `0.24.7 = 2.29`.

### `install.sh` refuses to run

It checks four things and refuses rather than half-deploy: the clone must be at
`~/.dotfiles-mise`, `~/.config` must be the default, an existing mise must be ≥ 2026.9.15 (older
releases silently drop the `permissions` entries and `[doctor.checks]` rather than failing — it
does not upgrade mise for you: `mise self-update`), and no `[dotfiles]` target or repo path may
still resolve into an old stow deployment. The messages name the offending path.

### `~/.ssh` or `~/.gnupg` has the wrong mode

They are permissions-only `[dotfiles]` entries (0700), so drift shows as `differs (permissions
differ)` in `mise bootstrap status` and `mise bootstrap dotfiles status`, and `mise bootstrap
dotfiles apply` fixes it. `mise bootstrap plan` does **not** show it — it does not cover
`[dotfiles]` at all. A `WARN ... ~/.ssh does not exist; permissions not set` means exactly that
and is harmless; the `pre-dotfiles` hook creates `~/.ssh` on every bootstrap to keep it quiet.

If you add another backup or cleanup pass keyed on `differs`, skip `mode: "permissions"` — a
permissions entry's target is a whole directory, and moving it aside moves your keys.

### `mise doctor project` reports a FAIL

Each check's hint line is the fix. They are the `[doctor.checks]` in `mise/config.toml` (plus
`nerd-font`, `i2c-membership` and `tree-sitter-runs` from the graphical, cosmic and neovim
profile files), each one a failure mode from this page. `i2c-membership` checks the *session's*
groups, so it keeps failing after `setup:cosmic` until you log out and back in.

---

## Testing gives wrong answers

### A fake-`$HOME` sandbox shows the real machine's config

mise resolves `<ancestor>/.config/mise/config.toml` from the **cwd**, independently of `$HOME`. A
sandbox whose fake home sits under the real one loads the machine's own config as a project
config — every assertion is then contaminated.

`sandbox/mkhome.sh` pins `TMPDIR=/tmp` for this reason. A hand-rolled probe must do the same;
putting one in a scratch directory under `$HOME` produces confidently wrong results.

### A tmux sandbox result looks impossible

oh-my-tmux resolves `TMUX_CONF` against literal real-`$HOME` paths, so a fake `$HOME` does **not**
isolate it — it loads the real `~/.config/tmux/tmux.conf.local` regardless. Plant a marker option
and confirm it took effect before believing anything a tmux sandbox tells you.

### `dconf` reports success but nothing changed

`dconf` resolves its writable backend through the session bus, not `$XDG_CONFIG_HOME`. Without a
session bus the write exits 0, the read-back is empty, and the real database is untouched. Always
read the value back.

### "That's impossible in a chained task"

Probably a tty artefact. A chained task *does* inherit the terminal when `mise bootstrap` is run
from one; a claim to the contrary came from a probe whose own shell had no controlling terminal.
Allocate a pty before concluding anything about interactivity:

```bash
script -qec "mise run <task>" /dev/null
```

### An idempotency bug that only shows on the second run

Run everything twice. A `config.local.toml`-being-eaten bug was invisible on a single run.

---

## Diagnostics worth knowing

```bash
mise bootstrap status                  # packages, repos, dotfiles, shell, tools
mise bootstrap dotfiles status --json  # per-entry state; `differs` is what the backup keys on
mise bootstrap dotfiles diff           # current vs desired, per entry
mise bootstrap repos status            # clone drift and dirty clones
mise config ls                         # which config files actually loaded
mise trust --show                      # what is trusted
mise doctor                            # dirs, settings and their source files
mise doctor project                    # this repo's [doctor.checks] — the probes plain doctor skips
mise tasks                             # every task and its description
mise run cleanup --dry-run         # dangling links into this repo
python3 scripts/lint-config.py --live   # collisions against the machine's conf.d
```

When docs and behaviour disagree, `mise <cmd> --help` on the installed binary wins. That has been
true often enough to be a rule — see [mise_behaviours.md](mise_behaviours.md).
