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

### A clone with a `ref` fails to fast-forward

`ref = "<branch>"` means **mise** fast-forwards it on every apply. If you have committed to that
branch locally, the fast-forward fails and aborts the bootstrap. A fork you commit to is a latent
whole-machine failure — either push it, or drop the `ref`.

### `files: sources do not exist`

A `[dotfiles]` entry with an **explicit** `source` that isn't there aborts the *entire* apply.
Nothing deploys — not the other thirty entries, not `.zshrc`.

Usually this means an entry points at something a later bootstrap step creates. Those links belong
in `setup:repo-links`, where a missing clone is only a warning. `python3 scripts/lint-config.py`
catches it before you push.

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
`mise config ls`, `mise dotfiles status` and `mise doctor` all stay quiet about it while the
profile silently stops applying.

```bash
mise run cleanup --dry-run
```

### A `conf.d/` drop-in has no effect

An **untrusted** drop-in is *silently ignored* — not an error. `mise dotfiles status` exits 0,
says nothing about trust, and the entries simply do not exist.

```bash
mise trust ~/.config/mise/conf.d/50-custom.toml
```

Note the asymmetry: an untrusted *global* config is a hard error, but a drop-in just vanishes.
`setup:custom-hookup` trusts its own drop-in because it creates it long after `install.sh`'s
trust loop has run.

### A `[dotfiles]` entry never deploys and nothing complains

An entry with **no source** (mirroring `dotfiles.root`) whose file is missing is silently ignored:
it never deploys, never appears in `mise dotfiles status`, and `--missing` still exits 0. A typo'd
target is invisible forever with every check green. `lint-config.py` stats every source precisely
because mise won't.

### Deselecting a profile left its files behind

There are no removal semantics, and `cleanup` won't help — the sources still exist, so the links
aren't dangling. This is a manual delete.

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

Unauthenticated GitHub API callers get 60 requests/hour, shared with every other tool on the
machine. Set `GITHUB_TOKEN` / `MISE_GITHUB_TOKEN`, or authenticate `gh`; `install.sh` resolves a
token from `$MISE_GITHUB_TOKEN` → `$GITHUB_TOKEN` → `$GH_TOKEN` → `gh auth token`.

Do **not** try to `mise exec`-install `gh` to get one: `mise exec TOOL@latest` is a "fast command"
hard-capped at 3 seconds regardless of `MISE_FETCH_REMOTE_VERSIONS_TIMEOUT`, and it needs the very
API that is failing. Also, `mise settings get <key>` echoes the raw env value unchanged — it never
confirms a value parses or applies, so don't use it as verification.

### `version 'GLIBC_2.39' not found` building treesitter parsers

The `neovim` profile's prebuilt `tree-sitter` carries a glibc floor that tracks its build runner,
and only one glibc asset ships. Ubuntu 22.04 has 2.35. Pin an older release in
`mise/config.neovim.toml`:

```toml
tree-sitter = "0.25.10"   # floor 2.34
```

Measured floors: `0.26.11 = 2.39`, `0.25.10 = 2.34`, `0.24.7 = 2.29`.

### `install.sh` refuses to run

It checks three things and refuses rather than half-deploy: the clone must be at
`~/.dotfiles-mise`, `~/.config` must be the default, and no `[dotfiles]` target or repo path may
still resolve into an old stow deployment. The messages name the offending path.

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
mise bootstrap status              # packages, repos, dotfiles, shell, tools
mise dotfiles status --json        # per-entry state; `differs` is what the backup keys on
mise bootstrap repos status        # clone drift and dirty clones
mise config ls                     # which config files actually loaded
mise trust --show                  # what is trusted
mise doctor                        # dirs, settings and their source files
mise tasks                         # every task and its description
mise run cleanup --dry-run         # dangling links into this repo
python3 scripts/lint-config.py --live   # collisions against the machine's conf.d
```

When docs and behaviour disagree, `mise <cmd> --help` on the installed binary wins. That has been
true often enough to be a rule — see [mise_behaviours.md](mise_behaviours.md).
