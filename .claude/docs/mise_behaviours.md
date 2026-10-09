# mise behaviours this repo is built around

Every entry here was established by running mise, not by reading about it — several contradict
what the documentation implies, and a few contradict what an earlier version of this file
claimed. **Re-verify on a mise version bump.** `sandbox/mkhome.sh` gives you a throwaway `$HOME`
to do it in.

Baseline: mise 2026.7.7 through 2026.7.13, re-verified against **2026.8.16** on 2026-09-01
(entries 8, 11, 18 and 25 changed; 32-36 are new). 37 was found on 2026.9.14. Re-verified against
**2026.9.15** on 2026-09-27: 5, 8, 11, 12, 27, 36 and 37 changed; 38-44 are new; 45-47 (the compose
and secrets resources, and per-profile values, measured for the `nextcloud` profile) were added on
2026-09-28; 49 (LuaTeX's font cache, for the Docker-based `latex` profile) on 2026-10-07; 50
(`activate_shims`, found from a shell-startup error) on 2026-10-09. The repo now requires
2026.9.15 (`install.sh` refuses older).

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

### 5. Trust is per-file — and mostly implicit for the global config directory

- `mise trust <dir>` does **not** cover the files inside it. One untrusted file makes every
  later mise call exit non-zero — which, under `pipefail`, killed `install.sh`. It now trusts
  each `config*.toml` and `conf.d/*.toml` individually.
- An untrusted **global** config is a hard error — in the demotion case below. The ordinary
  `~/.config/mise/config.toml` (and, since the reversal below, its `conf.d/`) is implicitly
  trusted: on 2026.9.15 the repo's linked config loaded with `mise trust --show` listing nothing.
- **Reversed on 2026.9.15:** an untrusted `conf.d/` drop-in *was* silently ignored on 2026.7.x —
  `mise bootstrap dotfiles status` exited 0, said nothing about trust, and the entries did not
  exist. Re-verified in a throwaway `$HOME` with `MISE_TRUSTED_CONFIG_PATHS` unset and `mise
  trust --show` listing nothing: a never-trusted drop-in in the global `conf.d` (a symlink into a
  companion under `$HOME`) now loads in full — `[dotfiles]`, `[env]` templates and `[tasks]`
  alike. Only `mise trust --ignore <file>` hides it, the same silent way (and that command
  answered `ignored ~`, i.e. it keyed on the config root, not the file). `setup:custom-hookup`
  and `install.sh` still trust the drop-in: free, and the old behaviour cost a whole companion.
  **Beware testing this from an agent shell:** this machine exports `MISE_TRUSTED_CONFIG_PATHS`,
  which a probe inherits unless it unsets it.
- A pre-existing real `~/.config/mise/config.toml` (any machine that used mise before) errors as
  untrusted once `MISE_GLOBAL_CONFIG_FILE` points elsewhere — the override appears to demote the
  normal global config out of implicit trust. `install.sh` backs it up before the first run.
  Still true on 2026.9.15 for a config with `[env]` templates / `[tasks]` (`Config files in
  ~/.config/mise/config.toml are not trusted`, rc 1); one holding only `[tools]` loads.

---

## `[dotfiles]`

### 6. A missing source fails in two opposite ways, both bad

- **Explicit `source` that doesn't exist → the entire apply aborts.** `mise ERROR files: sources
  do not exist`, and *nothing* deploys — not the other thirty entries, not `.zshrc`. One bad
  entry takes the whole machine down.
- **No source** (mirrored `dotfiles.root` path) and the file is missing → **silently ignored**.
  It never deploys, never appears in `mise bootstrap dotfiles status`, and `--missing` still exits
  0. A typo'd target is invisible forever with every check green.

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
on `mise bootstrap dotfiles status --json` reporting `state: differs`.

### 8. Removal is explicit, and only for entries you still declare

**Amended on 2026.8.16.** This entry used to say mise keeps no state database. It now does, for
part of the problem: managed `symlink-each` links are recorded under `$MISE_STATE_DIR/dotfiles`,
and `mise bootstrap dotfiles unapply` removes what the *current* config says an entry owns
(`--force` for modified copies, templates and plain-line edits). Upstream's own wording changed
with it — "because mise keeps no state database" became "because the active config still defines
which state belongs to an entry".

The gap that remains is the one this repo actually hits: **unapply reads the live config**, so it
cannot help once the entry is gone. Removing a `[dotfiles]` entry, or renaming a
`config.<profile>.toml`, still leaves the symlink in place pointing at a source that no longer
exists, and `mise config ls`, `mise bootstrap dotfiles status` and `mise doctor` all decline to
mention it while the profile silently stops applying. The order that works is **unapply first, then
delete the entry**; the `cleanup` task is the reaper for everything already orphaned, and only
removes links that are both dangling and pointing into this repo.

Note what `cleanup` does **not** do: deselecting a profile leaves its already-deployed files
alone, because the source still exists. Since 2026.9.13 mise covers that case —
`mise bootstrap unapply <profile>`, entry 39 — precisely because a deselected profile's config
file is still on disk: here the live-config rule works *for* you.

### 9. Self-managing config works, with two hard requirements

`mise/config.toml` declares the entries that link itself and its siblings into `~/.config/mise/`.
Globs expand per-file and pick up new files on re-apply — verified by adding a profile file and
running `mise bootstrap dotfiles apply` from an unrelated directory.

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

### 11. `source` is not templated — in `[dotfiles]` **or** `[bootstrap.files]`

`source = "{{ env.X }}/file"` is used as a literal path, which then "does not exist" and aborts
the whole apply (see 6). This is why the companion repo's absolute sources cannot follow the
clone, and why it must live at `~/.dotfiles-custom-mise`.

Re-verified on 2026.8.16, including against the 2026.8.x `config_source` template variable, which
does resolve a symlinked config to its real directory in `[env]`: `{{ config_root }}/src.txt` and
`{{ config_source | canonicalize | dirname }}/src.txt` were both reported verbatim, braces and
all, in the resolved source path. Again on 2026.9.14 inside a `conf.d` *folder* fragment (entry
43), where `{{ config_root }}` does render in `[env]` — to the folder — but a `source` of
`{{ config_root }}/home/x` came back `source missing` with the braces intact.

`[bootstrap.files].source` behaves the same way and **fails harder**. Verified through a config
reached by symlink: mise resolved the source against the *link's* directory, and `mise bootstrap
files status` died with `failed to read source …`, printing nothing at all — not a per-entry
warning. That is bootstrap step 3, so it takes dotfiles, tools and the whole tail with it. Use
inline `content` for privileged files and the question never arises; `scripts/lint-config.py`
rejects a relative source in either namespace.

### 12. mise creates missing parent directories with the process umask

Observed 0775 at umask 002. `gpg` refuses a group/world-readable `~/.gnupg`, and `ssh` refuses
a group/world-writable `~/.ssh`. Until 2026-09 a `pre-dotfiles` hook created and chmod'ed both,
doubled by a `[bootstrap.directories]` pair for reporting. Permissions-only `[dotfiles]` entries
replaced both (entry 38): they fix the mode in the same apply that creates the directory. The
hook survives only as `mkdir -p -m 700 ~/.ssh`, to spare an absent `~/.ssh` the per-apply
warning.

---

## Profiles and templates

### 13. `$MISE_ENV` reaches tasks but **not** hooks

`MISE_ENV=gnome,laptop` is observable inside a file task, so task-level profile gating works.
Inside `[bootstrap.hooks]` it is unset, and hook `run` strings are not template-rendered.
**Everything in a hook must be unconditional**; anything profile-dependent belongs in a task.

### 14. `mise_env` is *undefined*, not empty, when no profiles are selected

`env = []` is the shipped default, and `"x" in mise_env` on undefined is a hard Tera render error:
`` `in` cannot be used on a container of type `undefined` ``. A template that fails to render
aborts the **entire** `mise bootstrap dotfiles apply`, so sibling symlink entries don't deploy
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

2026.8.x adds a second way to express it: `[bootstrap.users.<name>].shell`, applied with
`usermod` inside mise's elevated helper rather than `chsh`, so it never PAM-prompts. This repo
still does not use it, for two reasons. The name cannot be templated (see 32), so only the
private companion repo could hold it; and the accounts step is bootstrap step **0**, which is
both before `apt:zsh` installs the shell it would point at and early enough that a failure to
elevate costs the entire run (see 32). NSS-managed accounts need the fallback task regardless —
they are not in `/etc/passwd`, so no `usermod` route can reach them.

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
already configured; it never adds a repo or a key. Up to 2026.9.14 it did not refresh their lists
either unless there were none at all; 2026.9.15 retries once after an `apt-get update` — see #37.

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

### 25. `mise bootstrap repos update` and `exec` exist as of 2026.8.x

**Reversed on 2026.8.16.** Through 2026.7.x the vendored docs described `repos update` and `repos
exec` in detail while `mise bootstrap repos --help` listed neither, and invoking them errored with
`unrecognized subcommand`. Both are now real, and `update` takes `--skip-dirty` (skip a dirty
checkout instead of failing the run) and `--dry-run` (print the git commands).

`update` fetches and fast-forwards exactly the unpinned class from 24 — the set mise otherwise
never touches after the first clone — and warns-and-skips a detached HEAD. `update:repos` was
rewritten around it and now only diagnoses: a bare invocation would also `checkout` + ff-pull a
ref-tracking repo whose state is `differs` (verified against `~/.tmux`), so the task passes the
unpinned paths explicitly to keep its contract.

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
GitHub token. That is the one 3s-capped step, and it needs the very API that is failing. Moot
since 2026.9.14 (entry 41): `install.sh` no longer fetches a token at all — it only passes on
one it finds.

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

### 49. LuaTeX's cached font tables change the PDF's text layer

Measured 2026-10-07 in `texlive/texlive:latest` (TeX Live 2026), building the Awesome-CV résumé
with `lualatex` and a persistent `$TEXMFVAR`: the first run, on an empty cache, extracts every
hyphen as U+2010 HYPHEN and matches the résumé's CI artifact (same size, fonts and text layer).
Every later run loads its per-font tables from `$TEXMFVAR/luatex-cache/generic/fonts` and extracts
U+00AD SOFT HYPHEN instead. The rendering is identical; only the text layer differs — and that is
what an ATS or a copy-paste reads. Extractors drop U+00AD, so "Scikit-Learn" becomes "ScikitLearn".

The font *index* next to it (`…/generic/names`, ~10 s to build) is safe to keep: with only the
tables fresh, three runs in a row all matched CI. `home/.local/bin/texlive` therefore persists
`$TEXMFVAR` per image ID and mounts an empty tmpfs over `fonts/` in each container — ~13 s a
build, against ~4 s fully cached (wrong) or ~25 s cold.

Two neighbouring facts the latex profile rests on, measured the same day:

- **The stock image is the one that matches CI.** Awesome-CV's workflow also apt-installs
  `fonts-roboto` and `fonts-adobe-sourcesans3` into it, but its artifact equals a stock build.
  Install them in a *local* image and luaotfload embeds Debian's copies instead (70 737 bytes
  against 55 121) — a build that no longer matches CI. So `install:latex` uses the image as-is.
- **Ubuntu 24.04 cannot build the current class from apt at all**: its TeX Live 2023 snapshot
  (2024-02-07) predates `fontawesome6` (CTAN, 2025-04), and no 24.04 package ships Source Sans 3
  (`fonts-adobe-sourcesans3` starts at 25.10). That is why the profile moved to Docker.

---

## New in mise 2026.8.x

### 32. The privileged declarative sections fail closed, at the earliest steps

`[bootstrap.users]`, `[bootstrap.groups]`, `[bootstrap.files]` and `[bootstrap.directories]` are
convergent and well-behaved — but when a change is pending and mise cannot elevate, the step
**errors and aborts the run**. There is no skip-what-needs-root mode: `system_packages.sudo =
false` is documented as "mise will print the command for you to run yourself instead", and it
does print it, then still exits 1 (verified).

Measured in a throwaway `$HOME`, no TTY, sudo requiring a password:

| declaration | fails at | cost |
| --- | --- | --- |
| `[bootstrap.files]` needing a write | step 3 | dotfiles, tools, tail — none of them ran |
| `[bootstrap.groups.<new>]` | step 0 | everything, earlier still |

With a TTY it is unremarkable: mise logs the exact command, `sudo` prompts once for the whole
batched plan, and it applies. That is the normal path on a personal machine, which is why
`config.cosmic.toml` does declare its udev rule and `i2c` group. The recovery on a machine that
cannot elevate is `mise bootstrap --skip accounts,files`.

Two consequences worth internalising: a privileged declaration converts a *partial* failure into a
*total* one (the imperative equivalent, `sudo_ok` + `skip`, costs only its own step), and nothing
in core `config.toml` should ever need root — keep that exposure inside a profile.

Also verified: `[bootstrap.users.<name>]` names are **not templated** — `[bootstrap.users."{{
env.USER }}"]` is rejected outright with `invalid bootstrap user name`. Anything user-specific
therefore belongs in the private companion repo, not here. Supplementary `groups` are additive by
default (`exclusive_groups = false`), so declaring one does not strip `sudo` or `adm`.

### 33. `raw = true` now takes an exclusive per-command lock

Upstream's warning that raw tasks "really screw up the output whenever mise runs tasks in
parallel", with its instruction to keep other tasks out of the way, is gone. A raw command now
holds an exclusive lock for as long as it runs, so mise will not run another command alongside it.
The lock is per *command*, not per task, so two raw tasks can still interleave between their
individual commands. Every file task in this repo is `raw=true`; the `[tasks.bootstrap]` chain is
sequential anyway, so nothing here depended on the old advice.

### 34. `manifest = "git"` makes `git ls-files` a hard dependency of the *whole* apply

The four `symlink-each` entries (`~/.claude/{commands,skills,agents}`, `~/.git-template/hooks`)
carry `manifest = "git"`, so mise walks `git ls-files` in the source directory instead of the
filesystem and the repo's index is the only filter. Measured on 2026.8.16 in a throwaway `$HOME`:
a stray untracked `home/.claude/commands/zz.md` is linked without the manifest (3 files) and
skipped with it (2), a link an earlier apply left behind is pruned on the next apply, and a
tracked file deleted from the repo takes its link with it while the directory stays.

The cost is that the manifest is resolved before **anything** is applied, and a failure there
aborts the entire step — not just that entry:

```
mise ERROR failed to locate Git repository for ~/.dotfiles-mise/home/.claude/commands:
           fatal: not a git repository (or any of the parent directories): .git
```

Nothing deployed in that run, `~/.zshrc` included. Two ways to trigger it: the repo is not a git
work tree (a tarball copy rather than a clone — the documented install path is a clone, so this is
accepted), or **`git` itself refuses to start**, which a corrupt `~/.gitconfig` does:
`fatal: bad config line 1 in file /home/<user>/.gitconfig`. That one was hit for real. Recovery is
`rm ~/.gitconfig` (or restore the source) and re-run; until then git needs
`GIT_CONFIG_GLOBAL=/dev/null` to run at all, including the `git checkout --` that fixes the source.

A bad `manifest` value is the same silent class as a bad `mode` (behaviour #6): `manifest = "gti"`
→ `unknown manifest 'gti', ignoring entry`; `manifest = "git"` on `mode = "symlink"` →
`manifest requires mode copy or symlink-each, ignoring entry`. Both are WARNings, both leave the
apply at exit 0 saying "no dotfiles configured", and the target is never created.
`scripts/lint-config.py` (`check_manifests`) rejects both, and CI asserts the filter still filters.

### 35. One `brew-cask` entry makes even the read-only commands network-dependent

Tested with `"brew-cask:font-fira-code-nerd-font" = "latest"` in a throwaway `$HOME`. The cask is
real and Linux font casks do install into `~/.local/share/fonts` — but the entry is resolved
against `formulae.brew.sh` on **every** command that touches `[bootstrap.packages]`, including the
ones that install nothing:

| command | online | offline (proxy refused) |
| --- | --- | --- |
| `mise bootstrap packages status` | `missing` | 3 retries, then exit 1 |
| `mise bootstrap plan --detailed-exitcode` | 2 (changes pending) | 1 (planning failed) |

A single unresolvable token is fatal to the whole plan, not just its own entry
(`font-totally-bogus-nope` → 404 → nothing planned at all). That would make `bootstrap status`
useless offline and would make CI's `plan --detailed-exitcode` gate report "a resource is unknown"
whenever the network hiccups. Fonts therefore stay in `setup:fonts`, which runs last, is gated on
the `graphical` profile, and `skip`s on a failed download. See also behaviour #32: `brew` creates
`/home/linuxbrew/.linuxbrew` with sudo, and packages are step 2 — before dotfiles and tools.

### 36. `mise dotfiles` was deprecated in favour of `mise bootstrap dotfiles` — then restored

`mise dotfiles --help` on 2026.8.16 opened with "Manage dotfiles from `[dotfiles]` (deprecated) —
use `mise bootstrap dotfiles` instead". **Reversed in 2026.9.8**: "The full dotfiles command tree
is now available as `mise dotfiles`, with `mise dot` as a short alias. `mise bootstrap dotfiles`
remains supported and all three spellings share the same behavior". On 2026.9.15 the `--help`
no longer says deprecated. Every call site in this repo (install.sh, CI, `sandbox/mkhome.sh`, the
docs) uses `mise bootstrap dotfiles`, now for consistency rather than necessity. Flags are identical across the two spellings: `status -J/--json/--missing`,
`apply -n/-y/-f`, `add --changed/-m/-s/-p/-g/-l/--no-apply`. The subcommand list also gained
`diff` (current vs desired, per entry — a file count for `symlink-each`), `unapply` (see #8) and
`edit`.

---

## Found on 2026.9.x

### 37. The packages step refreshed apt's lists only when there were none — fixed in 2026.9.15

`/var/lib/apt/lists` empty (a fresh container) → mise runs `apt-get update` before installing.
Lists present → it never does, however stale or incomplete they are. A freshly installed desktop is
the second case: on 2026-09-26 a new machine on 2026.9.14 died at the packages step with
`E: Unable to locate package nala` and `Package 'imagemagick' has no installation candidate`
(also pandoc, ffmpeg, python3-venv), and a manual `sudo apt-get update` was the whole fix. Since
packages are one batched install (#21), the one stale lookup took the entire bootstrap down with it.

The threshold is the vendored `bootstrap/packages/apt.md`'s ("Metadata refresh"); the failure is
what it looks like on a real machine. Two flags refresh, and only one is safe here:

- `mise bootstrap packages apply --update` — `apt-get update`, then the install.
- `mise bootstrap --update` — "refresh package manager metadata **and update configured repos**"
  (2026.9.13 `--help`), i.e. the unpinned clones of #24 get pulled too. Upgrades are opt-in in this
  repo, so this is not the fix.

**Fixed in 2026.9.15**: "On apt systems, mise now simulates the install first and runs `apt-get
update` once if the simulation fails." Measured in `ubuntu:24.04` after `apt-get update` and then
deleting the universe lists (so `nala` has no candidate): 2026.9.14 died `E: Unable to locate
package nala`, rc 1; 2026.9.15 fetched `noble-updates/universe` itself and installed, rc 0.
`install.sh` step 7c, which ran `sudo apt-get update` first for exactly this, was retired with the
move to a 9.15 floor.

Two caveats, both measured the same way on 2026.9.15:

- **mise treats `apt-get update`'s exit 100 as fatal.** With a broken third-party source on the
  machine (a vendor repo a task added, since moved or re-keyed) *and* stale lists, the retry's
  `apt-get update` fails on that one source (`Some index files failed to download`, exit 100)
  and mise aborts the packages step — the distro package it was fixing never installs. A manual
  `sudo apt-get update` refreshes the healthy sources anyway, after which the install works;
  with current lists no update runs and the broken source is irrelevant. The retired 7c had
  that tolerance (`|| warn`). A first install cannot hit this — vendor repos are added by the
  task tail, after packages — a re-run can.
- **The docs lag the behaviour.** The v2026.9.15 `bootstrap/packages/apt.md` still says mise
  "does not touch apt metadata" when lists exist, and `bootstrap/files.md` that "changing
  repository files does not automatically refresh metadata". The changelog and the binary say
  otherwise (entry 44).

### 38. Permissions-only `[dotfiles]` entries (2026.9.13) — and the backup trap they set

`"~/.ssh" = { permissions = "0700" }`: no source, no content, no mode. mise never creates the
target, never infers a source from `dotfiles.root`, and only chmods what exists. Measured on
2026.9.14/9.15 in throwaway `$HOME`s:

- A directory another entry creates in the same apply gets the mode — `~/.gnupg` via the
  `gpg-agent.conf` link, and `~/.ssh` via the companion's `~/.ssh/config` template, which lives
  in a *different* config file.
- It runs under `mise bootstrap --only dotfiles` and a standalone `mise bootstrap dotfiles
  apply` — the two paths `[bootstrap.directories]` never reached (entry 12).
- Drift: text `differs (permissions differ)`, JSON `mode: "permissions", state: "differs"`, and
  `dotfiles status --missing` exits 1. `mise bootstrap status` lists it; **`mise bootstrap plan`
  does not** — it covers no `[dotfiles]` at all ("nothing configured for bootstrap planning").
- Absent target: `WARN [dotfiles]."~/.ssh": ~/.ssh does not exist; permissions not set` on
  every apply; status counts it applied, so `--missing` stays 0.
- On a template, `permissions = "0600"` renders 0600 from a 0664 source, and a second apply is a
  no-op — status compares against the declared mode, not the source's.
- The silent class again (entries 6, 34): `permissions = 448` (a TOML int), `"0799"`, and
  permissions on `mode = "symlink"` are each a WARN, the entry dropped, rc 0. `"700"` is accepted.
  `lint-config.py` (`check_permissions`) rejects all three, plus a wildcard permissions-only key.

**The trap:** `differs` is what `install.sh` and `setup:custom-hookup` back up by `mv`-ing the
target aside. Before both learned to skip `mode: "permissions"`, a 0775 `~/.ssh` would have gone
to `~/.ssh.pre-mise.bak`, keys included — measured with the old filter, which printed `~/.gnupg`
and `~/.ssh` for a drifted sandbox. `scripts/dotfiles-targets.py` never lists these entries, and
CI's e2e plants a 0775 `~/.ssh` to keep it that way.

### 39. `mise bootstrap unapply <env>...` (2026.9.13) removes what a profile deployed

It loads `config.<env>.toml` even though the env is not selected and removes the dotfiles,
managed files, directories and user services it declares, plus empty parent directories mise
created. Measured on 2026.9.14/9.15:

- `unapply yazi graphical` with neither selected removed `~/.config/yazi`,
  `~/.config/ghostty/config{,.ghostty}` and the emptied `~/.config/ghostty`, kept core entries, and
  noted "N declaration(s) in [bootstrap.packages] are not removed by unapply: mise bootstrap
  packages prune --manager <manager>". A second run: "nothing to remove", rc 0.
- **It removes an env's resources even while the env is still selected** (`MISE_ENV=yazi mise
  bootstrap unapply --dry-run yazi` planned `rm ~/.config/yazi`). Pass only deselected profiles.
- An env with no config file (a task-only profile) → "nothing to remove", rc 0.
- The dry-run **plan goes to stdout**, the notes ("nothing to remove", the packages hint) to
  stderr — so an empty stdout means nothing to do. `setup:profiles` relies on that.
- Without a TTY and without `--yes` it refuses: "requires confirmation but there was nobody to
  ask", rc 1.

### 40. `[doctor.checks]` work from the global config (2026.9.6)

`mise doctor project` runs `[doctor.checks.<name>]` declared in `~/.config/mise/config*.toml`
from **any** cwd, with installed tools on `PATH` (`tree-sitter --version` passes), and exits 1
when one fails. Plain `mise doctor` does not run them. The default timeout is 10s and it is
real: a probe wrapping `mise run cleanup --dry-run` took 67s of CPU on this machine (the task
walks `~/.local/share`) and was reported `ERROR ... timed out after 60s` — which is why there is
no stale-links check. Checks are singletons like everything else (`doctor.checks` is a lint
namespace).

### 41. GitHub release metadata goes through mise-versions (2026.9.14)

For `github:` and `aqua:` tools outside the registry too, version listing, release lookup and
attestation lookup now go to `mise-versions.jdx.dev`. Measured on 2026.9.15 with `GITHUB_TOKEN`
unset and a throwaway `$HOME` (no gh login): `mise latest` over all 40 tools this repo declares
made 110 requests to mise-versions and 4 to `api.github.com` (neofetch and resvg fall back to it);
installing tuicr, gh-dash, btop, neofetch, doppler, hunk and croc made 82 and 4 (doppler's
release tag, neofetch). A tokenless install is nowhere near the 60/hour cap, which is why
`install.sh` stopped offering a `gh auth login`. mise falls back to `api.github.com` whenever
mise-versions fails other than with a 404, and private repos always go there.

### 42. `dotfiles status` text grew a history trailer

On 2026.9.14+ the human-readable `mise bootstrap dotfiles status` ends with `History: tracking
N entries …`, an `automatic capture: not declared …` hint and `Setup repository: none …` — from the
dotfiles-history feature, which this repo does not use. `--json` is unchanged. Nothing here parses
the text (CI only asserts it is non-empty), but a new text consumer must filter those lines.

### 43. `conf.d` *folder* fragments (2026.9.14) — measured for a possible companion move

Not adopted yet; recorded because it would lift two companion rules (CUSTOM.md 1 and 4).
`~/.config/mise/conf.d/50-custom -> ~/companion` (a folder holding `mise.toml`) loads; a relative
`source = "home/x"` resolves inside the folder **through the link**, and the deployed symlink
points through it too (`~/.x -> ~/.config/mise/conf.d/50-custom/home/x`); `mise.laptop.toml`
in the folder loads under `MISE_ENV=laptop`; a second apply is a no-op. Consequence: removing the
conf.d link — which `setup:custom-hookup` does when the live lint fails — would leave every
companion link dangling, so that safety net would need rethinking first. `source` is still not
templated (entry 11). 2026.9.15 also made tasks in a folder fragment run in that folder.

### 44. Vendor apt repos as `pre-packages` files: 9.15 fixes the refresh, not the blast radius

2026.9.5 added `phase = "pre-packages"` so `[bootstrap.files]` can write a repo definition and
its key before the packages step. Measured on 2026.9.15 in `ubuntu:24.04` with the 1Password repo
(armored key and deb822 `.sources`, both inline `content`) plus `apt:1password-cli` and a distro
`apt:tree`:

| case | result |
| --- | --- |
| root, repo healthy | files applied → install simulation fails → mise runs `apt-get update` → both installed, rc 0; second run fully converged |
| root, repo URL broken | `apt-get update` exit 100 → mise ERROR, rc 1 — `tree` **not** installed, nothing after the packages step ran, and the same on every re-run, because the declared file comes back |
| non-root, no sudo, no TTY | aborts at `system files (pre-packages)` — the first step — with the usual `sudo requires a password` hint; nothing installed |

So the refresh objection is gone, and the other two stand: a privileged declaration fails closed
(entry 32, now even earlier), and one vendor repo that breaks — a withdrawn release, a rotated
key, an outage — takes the whole machine's bootstrap down, distro packages included, until the
config is edited. A task loses one app and `skip`s. Also out of reach declaratively: this repo's
per-distro codename (`UBUNTU_CODENAME` over `VERSION_CODENAME`, for Mint), and `--no-remove` —
mise runs a plain `apt-get install -y -- <pkgs>`, so `docker-ce`'s `Conflicts: docker.io` would
silently remove a hand-installed `docker.io`. Vendor apps stay tasks (`lib/apt_repo.sh`).

### 45. `[bootstrap.compose]` fails closed when Docker is missing — at step 7, before dotfiles

Measured on 2026.9.14 and again on 2026.9.15, in `/tmp` sandboxes with a PATH that has no
`docker`, one compose project and one `[dotfiles]` entry as a marker:

| command | result |
| --- | --- |
| `bootstrap plan --detailed-exitcode` | `unknown compose:nc … unavailable: neither 'docker compose' nor 'docker-compose' was found`, rc **1** |
| `bootstrap --yes --only compose,dotfiles` | `refusing unsafe change to bootstrap compose project 'nc'`, rc 1, marker **not** deployed |
| `bootstrap --yes --skip tools,task` | same error, rc 1, marker **not** deployed |

Compose projects converge at step 7 of 18; `[dotfiles]` is step 9, tools 15 and `[tasks.bootstrap]`
17. This repo installs Docker at step 17 (`install:docker`, and entry 44 keeps it there), so a
compose project in any profile would kill the **first bootstrap of every fresh machine** with that
profile, before the task that would install Docker. `depends_on` only names bootstrap resources
(`package:…`, `service:…`), not tasks. The `unknown` state also makes CI's `plan` step exit 1 on any
sandbox arm without Docker.

Two more reasons it does not fit Nextcloud AIO in particular: AIO labels the sibling containers it
creates into the same compose project (verified on a real deploy, 2026-09-28:
`com.docker.compose.project=nextcloud-aio` on `nextcloud-aio-domaincheck`), and `remove_orphans`
**defaults to true** — it would delete them; and AIO recreates its own mastercontainer on update,
so a declarative owner would fight it. `install:nextcloud-aio` is a task for all three reasons.

### 46. A `secret()` in any file template blocks EVERY full bootstrap while the variable is unset

Measured on 2026.9.14 and 2026.9.15: `[bootstrap.secrets] x = "NC_TEST_PW"` plus a
`[bootstrap.files]` entry whose `content` uses `{{ secret(name="x") }}` (`template = true`), and a
`[dotfiles]` marker.

- Variable unset: `bootstrap --yes` → `failed to render template` / `required bootstrap secrets are
  unavailable: x (NC_TEST_PW)`, rc 1, **nothing ran** (marker not deployed) — the documented
  preflight, which resolves secrets before any phase.
- Variable set: applied, file 0600, rc 0.
- **Variable unset again, file already converged: rc 1 again.** The preflight renders every
  selected template on every run; a converged target does not exempt it. `bootstrap plan` → the
  file is `unknown`, rc 1.
- Still fine without it: `bootstrap --only dotfiles` (rc 0) and `bootstrap status` (reports
  `secret … missing` and `not inspected: required secret unavailable`, rc 0).

So a declared secret turns every routine `mise bootstrap --yes` on that machine into
`fnox exec -- mise bootstrap …` or `--prompt-secrets`. Nothing here declares one; Nextcloud AIO
generates and keeps its own secrets.

### 47. Per-profile values: `config.<env>.local.toml` gates natively; an `[env]` condition renders `""`

Measured on 2026.9.15, in `/tmp` sandboxes and then on the real machine, while moving the laptop's
`NEXTCLOUD_DATADIR` into the companion (2026-09-28):

- **`~/.config/mise/config.<env>.local.toml` is env-gated by mise itself**, and a symlink works:
  with `config.laptop.local.toml` declaring `[env] X`, `mise env` had X for `env = ["laptop"]` and
  `["docker", "laptop", "nextcloud"]`, and not for `["desktop"]` or `[]`. **This repo cannot use it
  from the companion.** `lint-config.py --live` reserves every `~/.config/mise/**` `[dotfiles]`
  target for the main `config.toml` ("self-management: … only the repo's config.toml may manage
  ~/.config/mise/** targets"), and `setup:custom-hookup` answered by unlinking the whole drop-in.
  Reverted and re-linked. On the way back it moved an unchanged `~/.ssh/config` to
  `.pre-mise.bak1` (content identical per `cmp`): harmless, but its backup can fire on a file with
  no real difference.
- **A `mise_env` condition in an `[env]` value works from a `conf.d` drop-in, but a false branch
  sets `""`, not unset.** `X = "{% if mise_env is defined and 'laptop' in mise_env %}v{% endif %}"`
  gave `'v'` with laptop (also inside `mise run` tasks), and `''` for `["desktop"]` and `[]`.
- **Compose passes the difference on.** `environment: X:` (map form, no value) with X unset renders
  `X: null` and the container gets no X (checked in a real throwaway container). With `X=""`
  exported it renders `X: ""` and the container gets an empty X. For AIO, an empty
  `NEXTCLOUD_DATADIR` is a value (`getenv` returns `""`, not `false`), which it would save as its
  datadir.

Consequences: the companion carries the laptop's datadir as a conditional `[env]` (CUSTOM.md,
*Device variants*), and `install:nextcloud-aio` unsets an empty `NEXTCLOUD_DATADIR` before calling
Compose. Any other consumer of a conditional `[env]` has to treat empty as absent the same way.

### 48. One source, several targets: explicit absolute sources back into this repo work (2026.9.15)

Measured for the `claude2` profile in a two-pass sandbox and then on a real machine: eight
`~/.claude-2/*` entries with `source = "~/.dotfiles-mise/home/.claude/..."`, five `symlink` and
three `symlink-each` with `manifest = "git"`, deploy alongside core's sourceless `~/.claude/*`
entries for the same files. A second apply is a no-op; `mise bootstrap unapply claude2` removes
exactly the eight (and the emptied `~/.claude-2`), leaving `~/.claude` untouched. Two things to
know:

- **A new profile file takes two applies to land.** The self-management glob
  (`~/.config/mise/config*.toml`) is expanded when the config loads, so the first apply after
  adding `config.<p>.toml` only links the file into `~/.config/mise/`; the profile's own entries
  deploy on the next one. In `--two-pass` sandbox mode the first pass never sees a profile at all,
  so its entries show as `missing` in the status that follows — that is the harness, not a bug.
- `lint-config.py` accepts the sources because they start with `~/.dotfiles-mise/` and resolve
  inside the checkout; any other absolute path outside the repo is an `OUT-OF-REPO SOURCE` error.

### 50. `mise activate` puts the shims on `PATH` (2026.9.2) — so project-only tools leak everywhere

`activate_shims` first appears in `settings.toml` at v2026.9.2 and defaults to **true**: full
activation (not just `--shims`) now adds the shims directory to `PATH`, for missing-version
auto-install and lazy tools. Measured on 2026.9.15: `mise activate zsh` in a clean environment
emits `export PATH='~/.local/share/mise/shims:…'`, and after the hook runs the shims sit after
every active tool's bin directory — a fallback, but on `PATH` in every cwd.

Consequence: every **installed** tool is a command everywhere, including one only a project's
`mise.toml` pins. Outside that project its shim exits 1 with `No version is set for shim: gcloud`
/ `Set a global default version …`, while `command -v` and zsh's `$commands` say it exists — so
anything that probes and then runs it fails. The case that surfaced it: Powerlevel10k's gcloud
segment (`_p9k_gcloud_prefetch`) checks `$+commands[gcloud]`, then runs `gcloud config
configurations describe` without silencing stderr whenever its stat-cache of the active gcloud
configuration misses — so the error showed on *some* new shells, not all.

`activate_shims = false` (env `MISE_ACTIVATE_SHIMS=false`) restores the pre-9.2 shape, measured in
a fresh `zsh -i`: no shims directory on `PATH`; `gcloud` absent from `~` (exit 127); inside the
project, after the hook, `$commands[gcloud]` is the real `installs/gcloud/…/bin/gcloud`; core
tools unchanged. The cost is the auto-install and lazy-tool behaviour above, which this repo
does not use (`task.run_auto_install = false` already). `mise activate --shims` still adds them.
`shims.exclude` is not the fix: it is a per-name list that deletes those shims outright, so every
project-only tool installed later would leak until someone added it.
