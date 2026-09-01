# Architectural patterns

Why each mechanism in this repo exists. The empirical facts these decisions rest on are in
[mise_behaviours.md](mise_behaviours.md); this file is the *reasoning*, that one is the
*evidence*.

---

## 1. Profiles: opt-in capability, not detection

A machine declares what it is in `~/.config/mise/miserc.toml`:

```toml
env = ["graphical", "cosmic", "ai", "dev", "yazi", "neovim", "media", "laptop"]
```

mise turns that into `$MISE_ENV`, which does two things: it loads the matching
`mise/config.<profile>.toml` files, and it is visible to file tasks, which gate on it via
`require_profile <name>` from `lib/profile.sh`.

**Why opt-in rather than detection.** The predecessor repo auto-detected almost everything —
whether a display existed, which desktop environment was running, which device tag applied — and
carried six separate per-machine state files to override the guesses. Detection conflates two
different questions:

- **Policy** — "should this machine have GNOME extensions?"
- **Capability** — "is gnome-shell installed and running right now?"

Profiles answer policy. Capability is still probed, but only as a `skip` guard, which is what
stops a bootstrap from failing on a box being provisioned over SSH before its first graphical
login. Listing a profile *is* the consent, which is why no task prompts "install X? [Y/n]".

**Profile files only ADD.** A `config.<profile>.toml` never redeclares a key that `config.toml`
declares — see pattern 2. A profile that only gates tasks needs no config file at all
(`veracrypt`, `tailscale`, `browsers`, `virt`); `laptop`/`desktop` are pure markers consumed by
templates.

**"Implies" is documentation, not mechanics.** `gnome` implying `graphical` is a note in the
README; list implied profiles explicitly.

### Adding a profile

Five touchpoints, and the lint only catches one of them:

1. `mise/config.<name>.toml` — only if it declares tools/packages/dotfiles
2. `KNOWN_PROFILES` in `install.sh` — **the lint fails without this**, and `install.sh` would
   warn-and-drop the name, silently seeding a machine without the profile
3. the profile list in `mise/miserc.example.toml`
4. the README profile table
5. ideally a `.github/workflows/ci.yml` sandbox matrix arm

---

## 2. One key, one file

No `[dotfiles]` target, `[bootstrap.repos]` path, tool, var or task may be declared in two
loadable config files — and, since mise 2026.8.x, no managed file, directory, group, user,
service, Compose project or firewall key either. They are convergent singletons with the same
undefined precedence, so the lint covers them from before the first entry exists.

This is not tidiness. mise's same-key precedence across sibling global configs is genuinely
inconsistent — two tests disagreed with each other and with the documented hierarchy. Rather
than depend on an order that isn't stable, the repo makes collisions impossible and has
`scripts/lint-config.py` fail the build on one. It runs in two modes:

- **repo mode** — every `mise/config*.toml`, plus a stat of every `[dotfiles]` source (mise
  silently ignores a missing *sourceless* entry, so nothing else would tell you)
- **`--live`** — loads the repo's keys as a baseline, then scans the machine's
  `~/.config/mise/conf.d/`, so a companion repo colliding with the main one is caught rather
  than silently resolved

The other checks it carries: self-management invariants, no relative `[dotfiles]` **or**
`[bootstrap.files]` sources, mode sanity, and the profile registry described above.

---

## 3. Self-managing mise config

`mise/config.toml` declares the `[dotfiles]` entries that deploy *itself*:

```toml
"~/.config/mise/config*.toml" = { source = "~/.dotfiles-mise/mise/config*.toml", mode = "symlink" }
"~/.config/mise/tasks"        = { source = "~/.dotfiles-mise/mise/tasks",        mode = "symlink" }
```

Add a profile file, run `mise dotfiles apply` from anywhere, and it is linked. Two hard
requirements (both from real bugs): sources must be **absolute**, and the glob must be
`config*.toml` rather than `*.toml`.

**`~/.config/mise` stays a real directory.** That is what lets `miserc.toml`, `conf.d/*.toml`
and an optional `config.local.toml` be genuinely machine-local — outside the repo, needing no
gitignore — while still loading normally. Making it a whole-directory symlink would drag
per-machine state into a shared repo, which is the mistake the predecessor made.

The chicken-and-egg of a first run (mise must find the config before the config is linked) is
broken by `install.sh` alone; afterwards nothing needs an environment variable.

---

## 4. The imperative tail, and why order is policy

`[tasks.bootstrap]` is the chain of file tasks that run after packages, repos, dotfiles and
tools. A member that exits non-zero **aborts every later member**.

That single fact dictates the whole shape:

1. **Wiring first** — `setup:custom-hookup` (the companion repo, whose data later steps read),
   `setup:repo-links`, `update:tmux-local`.
2. **What every machine needs, headless included** — `setup:completions`, `setup:git-signing`,
   `setup:login-shell-fallback`.
3. **The one interactive step**, `setup:p10k-icon --if-unanswered`, guarded so it asks at most
   once per machine and only at a terminal.
4. **Vendor apt repos** — `setup:apt-repos`, one pass, one `apt-get update`.
5. **Profile-gated installs**, last, where a bad day costs only themselves.

And it dictates the error convention in `lib/profile.sh`:

- **`fail`** — "this machine is in a state I refuse to guess about". Rare.
- **`skip`** — warn and exit 0. Everything environmental: no network, no sudo, no desktop
  session, no upstream asset for this release. The bootstrap continues.

**No prompts in the chain.** A chained task *does* inherit the terminal when the user runs
`mise bootstrap` from one — an earlier claim to the contrary was a testing artefact — but any
prompt hangs an unattended run, so decisions come from `#USAGE` flags, environment variables and
profile selection. `[[ -t 0 ]]` guards the tasks that are only useful interactively.

**Not in the chain, deliberately:** `setup:cosmic-theme` and `setup:cosmic-theme-clean` (menus),
`update:gnome-extensions` (writes and commits into *another* git repo), `setup:hostname` (asks),
and the `update:*` tasks generally. `update:tmux-local` is the exception — it needs no input and
on a clean merge only writes inside this repo.

---

## 5. Declarative where possible, tasks where necessary

The default is to declare. A task exists only when mise cannot express the thing:

| Belongs in config | Belongs in a task |
| --- | --- |
| apt packages from configured repos | anything needing a **third-party** apt repo |
| public git clones | a clone that might fail (private repo, no credentials) |
| files with a stable source | links into something an earlier step creates |
| tool versions, udev rules, groups | group **membership**, `udevadm` reload, `dconf`, `chsh` |

The two failure modes that force this:

- **Packages are batched into one `apt-get install`**, so one unresolvable name fails the whole
  step — before dotfiles, tools and the tail. Vendor apps therefore live in tasks with a `skip`.
- **A failing `[bootstrap.repos]` clone aborts the bootstrap at step 3**, so the private
  companion repo is cloned by `setup:custom-hookup`, which can decline and carry on.

`[bootstrap.user]` is declared **nowhere** for the same reason: it runs one PAM-prompting `chsh`
that fails on every unattended run, and it runs *before* the task step, so its failure would take
the whole tail with it — including the task written to handle exactly that case.

### The privileged sections, and the trade this repo accepted

2026.8.x moved two things out of `setup:cosmic` and into `config.cosmic.toml`: the ddcutil udev
rule (`[bootstrap.files]`) and the `i2c` group (`[bootstrap.groups]`). Both now show up in
`mise bootstrap status` and `mise bootstrap plan`, which a task could never do — it can only
repair drift silently.

The price is the failure shape. A task gates on `sudo_ok` and `skip`s, so a machine that cannot
elevate loses that one step. These sections instead **fail closed and abort the run**, at steps 0
and 3, before dotfiles and tools; `system_packages.sudo = false` does not soften it. Measured, not
assumed — see `mise_behaviours.md` 32.

That is acceptable here for one reason: with a terminal, mise logs the command and prompts once,
which is the normal path on the personal machines `cosmic` targets. It follows that **nothing in
core `config.toml` may declare a privileged resource** — the exposure stays inside a profile, and
the recovery is `mise bootstrap --skip accounts,files`. The membership (`usermod -aG`) stays in the
task regardless: `[bootstrap.users]` needs a literal user name, which a public repo does not have.

---

## 6. Deployment modes, and the dangerous one

| Mode | Use | Behaviour on a conflict |
| --- | --- | --- |
| `symlink` | almost everything | refuses to overwrite an existing file |
| `symlink-each` | a directory that must stay real | per-file links |
| `copy` | files a tool rewrites in place | replaces |
| `template` | per-machine variants | **destroys a pre-existing real file, silently** |

Template mode is the single most dangerous thing in the repo: it replaces the target with no
error and no backup. `install.sh` moves conflicting real targets aside to `<file>.pre-mise.bak`
before the first apply, keyed on `mise dotfiles status --json` reporting `differs` — deliberately
*not* filtered by mode, since the mode that needs it most is the one that doesn't complain.

Template gating must guard against an unconfigured machine:

```jinja
{% if mise_env is defined and "laptop" in mise_env %}
```

`mise_env` is **undefined**, not empty, when `env = []` — and a template that fails to render
aborts the entire apply, taking unrelated symlink entries with it.

**Sensitive directories are never whole-directory symlinks** (`~/.gnupg`, `~/.config/gh`,
`~/.claude`, `~/.ssh`) so live tokens and keys cannot land in the repo tree. A `pre-dotfiles`
hook creates `~/.gnupg` and `~/.ssh` at 0700 first, because mise would otherwise create them at
the process umask and both gpg and ssh refuse a too-permissive directory.

---

## 7. Removal is manual, and that is a design position

mise records `symlink-each` links under `$MISE_STATE_DIR/dotfiles` and offers `mise bootstrap
dotfiles unapply`, but it reads the **live config** to decide what an entry owns — so it helps
only while the entry still exists. The order that works is unapply, *then* delete the entry.

Removing the entry first leaves its symlink and nothing reports it. `mise run cleanup` is the
reaper for that case, and it is deliberately narrow: it removes only links that are **both**
dangling **and** pointing into this repo.

What it will not do is undo a *working* deployment. Deselecting a profile leaves its files in
place, because their sources still exist. That is a manual delete, and `README.md` says so.

---

## 8. Upgrades are opt-in

Every task that installs a third-party application (`ghostty`, `obsidian`, `veracrypt`, `zen`,
and the six vendor-repo apps) follows the same rule:

- **not installed** → install, unattended. A fresh machine needs no flags.
- **installed and current** → say so, do nothing.
- **installed and outdated** → *report* the available version and exit 0. Upgrading needs
  `--update`.

The reason is that `mise bootstrap` is expected to be safe to run at any moment, and swapping a
running terminal's, editor's, browser's or VPN daemon's binary underneath it is not safe. The
`update:*` tasks are the deliberate path for "I have decided to upgrade"; they never install
something from scratch, because that would resurrect an app on a machine that removed it.

---

## 9. Vendor apt repositories

`lib/apt_repo.sh` centralises the six third-party repos. Three decisions worth knowing:

- **Detection uses `apt-get indextargets`, not a grep of `sources.list.d`.** That directory is
  not a list of active repos — it accumulates `*.save` and `*.disabled` files apt never reads,
  and commented-out `deb` lines. A grep matches those, concludes "already configured", and the
  install then fails "Unable to locate package" forever.
- **Keyrings use each vendor's canonical filename.** `brave-keyring`'s postinst greps the sources
  file for its exact expected path and, failing to match, symlinks the key into
  `/etc/apt/trusted.gpg.d/` — where it is trusted for *every* repo on the machine, defeating
  `signed-by`.
- **The suite comes from `UBUNTU_CODENAME`, falling back to `VERSION_CODENAME`.** On Mint the
  latter is the Mint release name and the vendors publish only the Ubuntu base.

Installs pass `--no-remove`, because `docker-ce` declares `Conflicts: docker.io` with no
`Replaces`, so a plain `apt-get install -y` satisfies the conflict by *deleting* a package the
user installed by hand.

`setup:apt-repos` adds every active profile's repos in one pass with one `apt-get update`; each
install task can still add its own, for a hand-run on a machine that never ran the chain.

---

## 10. The private companion repo

Anything unshareable — identity, keys, host lists, work config — lives in a second repo with the
same shape (`~/.dotfiles-custom-mise`), whose `mise/config.custom.toml` is linked into
`~/.config/mise/conf.d/50-custom.toml`.

It is wired up by a **task**, not `[bootstrap.repos]`, because a clone that fails aborts the
whole bootstrap and a private repo fails to clone on exactly the machines that most need the rest
of it — CI, a fresh box before its keys exist, anyone else using this repo.

Its contract (full version in `CUSTOM.md`):

- every entry needs an explicit absolute `source` — `dotfiles.root` belongs to this repo
- it may not redeclare a key this repo declares, or define `[tasks.bootstrap]`
- its sources must exist whenever its config file does, since a missing explicit source aborts
  the entire apply — this repo's files included
- it must live at `~/.dotfiles-custom-mise`, because `[dotfiles].source` is not templated

`setup:custom-hookup` removes the drop-in link again if the live lint fails, so a broken
companion cannot take the main repo down. It also `mise trust`s the drop-in itself: an untrusted
`conf.d` file is *silently ignored*, not an error.

---

## 11. Verification

- **`sandbox/mkhome.sh`** — a throwaway `$HOME`. It pins `TMPDIR=/tmp` because mise resolves
  `<ancestor>/.config/mise/config.toml` from the cwd regardless of `$HOME`, so a fake home under
  the real one is contaminated by the machine's own config.
- **`mise run repo:lint`** — the same file set as CI: config lint (repo + `--live`), python
  syntax, ruff, shellcheck, shfmt, `bash -n`, `zsh -n`.
- **`.github/workflows/ci.yml`** — three jobs: `lint`, a `sandbox` matrix across five profile
  combinations, and `e2e`, a real `ubuntu:24.04` container with a non-root passwordless-sudo user
  that runs `install.sh` **twice** and diffs the symlink graph for idempotency.
- **`.github/workflows/freshness.yml`** — monthly, for upstream drift.

Two rules that come from bugs testing alone missed: **run everything twice**, and for anything
privileged, **stub `sudo`/`apt-get`/`curl` on `PATH` and assert on the logged command lines**
rather than executing them.
