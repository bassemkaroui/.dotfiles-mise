# mise behaviours this repo is built around

Every entry here was established by running mise, not by reading about it — several contradict
what the documentation implies, and a few contradict what an earlier version of this file
claimed. **Re-verify on a mise version bump.** `sandbox/mkhome.sh` gives you a throwaway `$HOME`
to do it in.

Baseline: mise 2026.7.7 through 2026.7.13.

The general lesson, which has been paid for repeatedly: **`mise <cmd> --help` on the installed
binary beats the vendored docs**, and a sandbox result beats an argument.

---

## Config resolution and precedence

### 1. Same-key precedence across sibling global configs is inconsistent — treat it as undefined

Two independent tests disagreed with each other *and* with the documented hierarchy: in one,
`config.toml` beat `config.laptop.toml`; in another, `config.desktop.toml` beat `config.toml`,
and with two active profile files the last-listed one won silently.

**Consequence — the repo's central design rule:** no `[dotfiles]` target, repo path, tool, var
or task may be declared in two loadable files. This is enforced by `scripts/lint-config.py`,
not by convention, because convention cannot survive a profile file someone adds later.

### 2. `MISE_GLOBAL_CONFIG_FILE` restricts rather than relocates

While it is set on a **fresh** machine, mise loads *only* that file: `config.<profile>.toml`,
`conf.d/*.toml` and `config.local.toml` are all invisible. A first run done entirely under the
variable would install core only and silently ignore every selected profile.

Hence `install.sh`'s two-pass design: pass one is `mise bootstrap --only dotfiles` with the
variable set (just enough to create the config links), then it unsets and runs the real
bootstrap.

Once `~/.config/mise/config*.toml` exist as links, the profile files *do* load even with the
variable set — they are then found as siblings of the real global config path. So diagnostics
run with the variable on a deployed machine are not as blind as on a fresh one. Either way:
when probing, check both with and without it.

### 3. mise discovers `<ancestor>/.config/mise/config.toml` from the cwd, independently of `$HOME`

With `HOME` pointed at a throwaway directory, `cd /` resolves clean — but from **any cwd under
the real home**, mise loads the real `/home/<user>/.config/mise/config.toml` as a project config
and errors on it if untrusted.

Harmless for real users. Fatal for testing: **a sandbox whose fake `$HOME` sits under the real
one is silently contaminated by the machine's own config.** `sandbox/mkhome.sh` pins
`TMPDIR=/tmp` for this reason, and `install.sh` `cd`s to `$HOME` before invoking mise. A
hand-rolled probe in a scratch directory under `$HOME` will produce confidently wrong results.

### 4. The repo's own `mise/config.toml` is auto-discovered as a project config

`cd` into the repo and `mise config ls` lists it plus the profile files. Harmless — same files,
deduped by path, no double-apply. It does mean "keep tools out of a repo-root seed so the repo
directory doesn't shadow globals" was never a real mitigation. Renaming `mise/` would make it
undiscoverable, if repo-directory inertness ever matters.

### 5. Trust is per-file, and the two failure modes are opposite

- `mise trust <dir>` does **not** cover the files inside it. One untrusted file makes every
  later mise call exit non-zero — which, under `pipefail`, killed `install.sh`. It now trusts
  each `config*.toml` and `conf.d/*.toml` individually.
- An untrusted **global** config is a hard error.
- An untrusted **`conf.d/` drop-in is silently ignored** — `mise dotfiles status` exits 0, says
  nothing about trust, and the drop-in's entries simply do not exist. This is what the companion
  repo would hit on a fresh machine, where the drop-in is created near the end of the bootstrap
  chain, long after `install.sh`'s trust loop. `setup:custom-hookup` therefore trusts it itself.
- A pre-existing real `~/.config/mise/config.toml` (any machine that used mise before) errors as
  untrusted once `MISE_GLOBAL_CONFIG_FILE` points elsewhere — the override appears to demote the
  normal global config out of implicit trust. `install.sh` backs it up before the first run.

---

## `[dotfiles]`

### 6. A missing source fails in two opposite ways, both bad

- **Explicit `source` that doesn't exist → the entire apply aborts.** `mise ERROR files: sources
  do not exist`, and *nothing* deploys — not the other thirty entries, not `.zshrc`. One bad
  entry takes the whole machine down.
- **No source** (mirrored `dotfiles.root` path) and the file is missing → **silently ignored**.
  It never deploys, never appears in `mise dotfiles status`, and `--missing` still exits 0. A
  typo'd target is invisible forever with every check green.

**Consequences:** no entry may point at something an earlier bootstrap step creates — the
first-run pass applies dotfiles *before* cloning repos, so an entry into a clone bricks a fresh
install. Those links are made by `setup:repo-links`, where a missing clone is only a warning.
And `lint-config.py` stats every source, because mise won't tell you.

### 7. `mode = "template"` destroys a pre-existing real file, silently

Verified against a real `~/.ssh/config`: `mise files: applied ~/.ssh/config`, contents replaced,
no error and no backup. `mode = "symlink"` in the same position refuses with "refusing to
overwrite existing files". Template mode also replaces a symlink without comment — a symlink is
never data to mise.

`install.sh`'s conflict backup therefore must not filter on mode (it did once; fixed). It keys
on `mise dotfiles status --json` reporting `state: differs`.

### 8. There are no removal semantics

Removing a `[dotfiles]` entry, or renaming a `config.<profile>.toml`, leaves the symlink in
place pointing at a source that no longer exists. `mise config ls`, `mise dotfiles status` and
`mise doctor` all decline to mention it while the profile silently stops applying. The `cleanup`
task is the missing reaper; it only removes links that are both dangling and pointing into this
repo.

Note what `cleanup` does **not** do: deselecting a profile leaves its already-deployed files
alone, because the source still exists. That is a manual delete.

### 9. Self-managing config works, with two hard requirements

`mise/config.toml` declares the entries that link itself and its siblings into `~/.config/mise/`.
Globs expand per-file and pick up new files on re-apply — verified by adding a profile file and
running `mise dotfiles apply` from an unrelated directory.

- Sources **must be absolute**. A relative source resolves against the declaring file's
  directory, which after linking is `~/.config/mise` — i.e. self-referential entries that never
  pick up repo changes.
- The glob must be `config*.toml`, not `*.toml`, or it sweeps in `miserc.example.toml`.

`~/.config/mise` stays a **real directory**, which is what makes `miserc.toml` and `conf.d/*.toml`
genuinely machine-local while still loading.

### 10. `--force` / `--force-dotfiles` is never safe here

mise's own conflict error recommends it. On the self-management entries it overwrites the
committed `mise/config*.toml` with self-referential symlink loops and silently drops the global
config. Resolve conflicts by moving the offending file aside — which is what `install.sh` does.

### 11. `[dotfiles].source` is not templated

`source = "{{ env.X }}/file"` is used as a literal path, which then "does not exist" and aborts
the whole apply (see 6). This is why the companion repo's absolute sources cannot follow the
clone, and why it must live at `~/.dotfiles-custom-mise`.

### 12. mise creates missing parent directories with the process umask

Observed 0775 at umask 002. `gpg` refuses a group/world-readable `~/.gnupg`, and `ssh` refuses
a group/world-writable `~/.ssh`, so a `pre-dotfiles` hook creates both at 0700 first. Applying
does not touch the mode of an existing directory, so it converges.

---

## Profiles and templates

### 13. `$MISE_ENV` reaches tasks but **not** hooks

`MISE_ENV=gnome,laptop` is observable inside a file task, so task-level profile gating works.
Inside `[bootstrap.hooks]` it is unset, and hook `run` strings are not template-rendered.
**Everything in a hook must be unconditional**; anything profile-dependent belongs in a task.

### 14. `mise_env` is *undefined*, not empty, when no profiles are selected

`env = []` is the shipped default, and `"x" in mise_env` on undefined is a hard Tera render
error: `` `in` cannot be used on a container of type `undefined` ``. A template that fails to
render aborts the **entire** `mise dotfiles apply`, so sibling symlink entries don't deploy
either.

Every profile-gated template must guard: `{% if mise_env is defined and "laptop" in mise_env %}`.
This is the same shape of bug as 6 and 20 — a profile mechanism that works on a configured
machine and silently breaks the default one.

---

## The bootstrap chain

### 15. A failing chain member aborts every later member

`{ task = "x" }` entries in `[tasks.bootstrap].run` execute **sequentially** in declaration
order (`depends` would parallelise them). A member that exits non-zero kills the rest and makes
`mise bootstrap` exit with that member's code — verified: a → b(exit 3) → c ran a and b, never
c, rc=3.

This is the single most design-shaping fact in the repo. An optional install that can't reach
the network would otherwise cost the machine its completions, git signing and login-shell
fallback. Hence: essential steps first, optional last, and `lib/profile.sh`'s `skip` (warn +
exit 0) for everything environmental.

A stale `#MISE depends=[...]` naming a task that no longer exists fails the same way
(`ERROR task not found`, rc=1).

### 16. Chained tasks *do* inherit the terminal

An earlier version of this finding said the opposite. That was an artefact of the test harness —
the shell running the probe had no controlling terminal itself. Re-run under a real pty
(`script -qec "mise run chain" /dev/null`), a chained task reports `-t 0` true and opens
`/dev/tty` fine.

So a prompt inside the chain *works* when the user runs `mise bootstrap` from a terminal. It is
still banned, for the weaker but sufficient reason that any prompt hangs an unattended run.
Use flags, env vars and profile decisions instead. `[[ -t 0 ]]` is the right guard for a task
that is only useful interactively.

**The durable lesson: "X is impossible", measured from a tty-less agent shell, is not a property
of mise.** Allocate a pty before concluding anything about interactivity.

### 17. `[bootstrap.hooks.final]` offers no failure isolation

It runs after `[tasks.bootstrap]`; it inherits the terminal exactly like a task; `$MISE_ENV` is
unset inside it, so it cannot be profile-gated; and a hook that exits non-zero aborts the
remaining hooks and fails the bootstrap. Hooks also only run on `mise bootstrap`, never on
`mise run bootstrap`, and run in the caller's environment without `[tools]` on `PATH` (hence
`mise exec --` for anything that needs a tool).

Moving the optional installs there would lose profile gating and `mise run bootstrap`
re-runnability while gaining nothing.

### 18. `[bootstrap.user]` is a trap — this repo declares none

It runs exactly one command, bare `chsh -s <shell>` (plus appending to `/etc/shells`, for which
it will use sudo). No `sudo chsh`, no `usermod`. Bare `chsh` PAM-prompts, so it fails on every
unattended run — and the `user` step runs *before* the task step, so its failure means
`[tasks.bootstrap]` never starts and `install.sh` dies with it under `pipefail`. The step meant
to rescue exactly this case was therefore unreachable in the case it was written for.

`setup:login-shell-fallback` owns the login shell instead: sudo chsh → sudo usermod →
interactive chsh → `exec zsh` in `~/.bash_profile`, each rung tried only where it can work.
Upstream offers no tolerate-failure knob.

### 19. `#USAGE` flags are real environment variables

`#USAGE flag "--yes"` exports `usage_yes=true`, and leaves it unset when the flag is absent, so
`${usage_yes:-false}` is the correct idiom. Dashes become underscores (`--if-unanswered` →
`usage_if_unanswered`). Prefer these over hand-rolled argument parsing.

### 20. Executable files under `tasks/lib/` are listed as tasks

An executable `tasks/lib/helper` shows up and runs as `lib:helper`. Non-executable ones are
ignored. Shared helpers therefore ship **mode 644** and are `source`d (or invoked as
`python3 "$HELPER"`). Sourcing `../lib/foo.sh` works through the `~/.config/mise/tasks` symlink.

---

## `[bootstrap.packages]` and `[bootstrap.repos]`

### 21. mise batches all apt packages into one `apt-get install`

So a single unresolvable package name fails the **whole** packages step — which is step 2, before
dotfiles, tools and the entire imperative tail. Verified in a sandbox: with one bogus entry
added, `zsh git curl build-essential …` were in the same failing command and `[tasks.bootstrap]`
never ran.

This is why every vendor app (one whose packages live in a third-party repo) is a task with a
`skip`, never a `[bootstrap.packages]` entry. mise's apt manager installs from repos that are
already configured; it never adds a repo or a key.

### 22. `[bootstrap.repos]` is all-or-nothing, and `url` is not templated

A clone that fails — no credentials, private repo, typo'd URL — exits the bootstrap non-zero at
step 3, so `[dotfiles]`, the tools and the whole tail never run. And `url = "{{ env.SOMETHING }}"`
is taken literally.

Anything whose availability is uncertain (a private companion repo) must be cloned by a **task**,
which can decline. Public, always-reachable repos are fine as entries.

### 23. Any untracked, non-gitignored file in any clone aborts the whole bootstrap

`mise ERROR repos: ~/x has local changes; commit, stash, or clean them before bootstrap`, rc=1,
at step 2. One file in one clone is enough.

**Gitignored files are fine** — which makes `printf '<name>\n' >> <clone>/.git/info/exclude` the
cheapest fix for generated content, and the one to recommend: local to the clone, no upstream
change needed. `install.sh` pre-flights `repos status --json` and refuses with the paths and the
remedies; `update:repos` reports the same set.

### 24. Who updates a clone is the opposite of what "pinned" suggests

- `ref = "<branch>"` → **mise fast-forwards it on every apply.**
- `ref` pointing at a **diverged** local branch → the fast-forward fails and **aborts the
  bootstrap**. A fork you commit to is a latent whole-machine failure.
- **No `ref`** → mise never touches it again after the first clone; "an existing repo with the
  expected origin is considered current". Verified against a clone sitting still while upstream
  was two commits ahead.

`update:repos` exists for that last set.

### 25. `mise bootstrap repos` has only `apply` and `status`

The vendored docs describe `repos update` and `repos exec` in detail. `mise bootstrap repos
--help` lists neither, and invoking them errors with `unrecognized subcommand`. `update:repos`
does the git work itself.

---

## Tools

### 26. The `pipx:` backend needs `uv`, not `pipx`

"The pipx backend will actually default to using uvx … if uv is installed." Verified in an
`ubuntu:24.04` container with **neither pipx nor python3** installed: declaring `uv` alongside
`"pipx:urlscan"` in the same `[tools]` table is enough — mise installs uv first, then runs
`uv tool install`. A tool declared through the pipx backend therefore makes `uv` a hard *core*
dependency, not a profile one.

### 27. `fetch_remote_versions_timeout` is hard-capped to 3s for "fast commands"

Shims, shell activation and `mise exec TOOL@latest` use `prefer_offline` and cap at 3.00s no
matter what `MISE_FETCH_REMOTE_VERSIONS_TIMEOUT` says — the override is silently ignored on that
path. The real bootstrap tool installs are *not* fast commands and do honour the full timeout.

Corollary that bit `install.sh`: do not try to `mise exec`-install `gh` in order to fetch a
GitHub token. That is the one 3s-capped step, and it needs the very API that is failing. Use
`gh` only if already present, else take a pasted token.

Also: `mise settings get <key>` **echoes the raw env value unchanged** (even `bogus`), so it
never confirms that a value parses or is applied. Do not use it as verification.

---

## Not mise, but load-bearing

### 28. apt's git is linked against `libcurl-gnutls`, which truncates large packs over HTTP/2

Verified on a real machine, no container: cloning oh-my-zsh with `/usr/bin/git` fails with
`RPC failed; curl 56 GnuTLS recv error (-24)` → `early EOF` → `fetch-pack: invalid index-pack
output`. The same git with `http.version=HTTP/1.1` clones 26 MB cleanly, and the OpenSSL-linked
`conda:git` clones cleanly over HTTP/2.

Why it is a bug and not trivia: `[bootstrap.repos]` clones at step 2 with whatever git is on
`PATH` — on a fresh machine, apt's — while `conda:git` is a `[tools]` entry installed at step 9.
Combined with 22, a fresh install died at step 2 with nothing deployed. `install.sh` detects the
linkage (`ldd $(git --exec-path)/git-remote-https`) and exports `GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1` — an env override, because
`~/.gitconfig` at that moment is neither deployed nor safe to create.

### 29. oh-my-tmux is self-referential — its config must *be* the file, not point at it

Its `.tmux.conf` computes `TMUX_CONF` as the first existing path among `~/.tmux.conf`,
`$XDG_CONFIG_HOME/tmux/tmux.conf`, `~/.config/tmux/tmux.conf`, then runs
`cut -c3- "$TMUX_CONF" | sh -s _apply_configuration` — it executes shell code embedded in its own
config file. A `source-file` shim would make `TMUX_CONF` the *shim*, so `_apply_configuration`
and the `bind +` / `bind m` / `bind F` helpers would all read the wrong file and silently do
nothing. A symlink is required.

The same literal-path resolution means a fake-`$HOME` sandbox **does not** isolate oh-my-tmux:
it will happily load the real `~/.config/tmux/tmux.conf.local`. Plant a marker option and check
it took effect before believing any tmux sandbox result.

### 30. `dconf` exits 0 even when it has nowhere to persist a write

It resolves its writable backend through the session bus, not `$XDG_CONFIG_HOME`. With no
session bus (or a fake `$HOME`) the write succeeds, the read-back is empty, and the real database
is untouched. Anything that "configures" via dconf must read the value back to know whether it
did anything. Separately, `dconf load` *does* exit 1 on a malformed key file, so it needs a guard
inside a chain member.

### 31. The prebuilt `tree-sitter` carries a glibc floor that tracks its build runner

`tree-sitter = "latest"` resolved to 0.26.11, whose `tree-sitter-linux-x64` needs **GLIBC 2.39**;
Ubuntu 22.04 has 2.35, so nvim-treesitter's parser build dies with ``version `GLIBC_2.39' not
found``. Only one glibc asset ships — no musl or static variant — so the prebuilt is inherently
glibc-floored. Measured floors: `0.26.11 = 2.39`, `0.25.10 = 2.34`, `0.24.7 = 2.29`.

This is why the repo declares Ubuntu 24.04+ / glibc ≥ 2.39. A 22.04 user's escape hatch is
pinning `tree-sitter = "0.25.10"`.
