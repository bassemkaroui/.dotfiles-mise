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
`[bootstrap.files]` sources, and sanity for every `[dotfiles]` value mise would drop with a mere
warning — `mode`, `manifest` and `permissions` — plus the profile registry described above.
`[doctor.checks]` names are a collision namespace too.

---

## 3. Self-managing mise config

`mise/config.toml` declares the `[dotfiles]` entries that deploy *itself*:

```toml
"~/.config/mise/config*.toml" = { source = "~/.dotfiles-mise/mise/config*.toml", mode = "symlink" }
"~/.config/mise/tasks"        = { source = "~/.dotfiles-mise/mise/tasks",        mode = "symlink" }
```

Add a profile file, run `mise bootstrap dotfiles apply` from anywhere, and it is linked. Two hard
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
| directory modes (`permissions`), health probes (`[doctor.checks]`) | the fix a failed probe points at |

The two failure modes that force this:

- **Packages are batched into one `apt-get install`**, so one unresolvable name fails the whole
  step — before dotfiles, tools and the tail. Vendor apps therefore live in tasks with a `skip`.
  Re-checked on 2026.9.15 against the declarative alternative — the repo and key as
  `phase = "pre-packages"` `[bootstrap.files]`: mise now refreshes the lists for it, but a
  broken vendor repo still fails the whole step on every run, distro packages included, and the
  files need root before anything else runs (behaviour 44).
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

### A service whose settings live in its own interface: record and check

Nextcloud AIO (the `nextcloud` profile) fits neither column. Its settings live in its web
interface and in a `configuration.json` it shares with secrets it generates, and upstream
documents no file or variable for them. The pattern used instead:

- the **launch** config is a file: `services/nextcloud-aio/compose.yaml`;
- a **task** creates the container when absent and starts it when stopped, and otherwise stays out
  of the way (AIO updates and recreates it itself);
- the **interface** settings are recorded in `services/nextcloud-aio/settings.toml`, printed as a
  checklist until setup is done, and compared read-only by `[doctor.checks]`.

The declarative alternatives were measured and rejected: a `[bootstrap.compose]` project kills a
fresh machine's first bootstrap at step 7, before Docker exists (behaviour 45), and a
`[bootstrap.secrets]` input makes every full bootstrap fail while its variable is unset
(behaviour 46).

---

## 6. Deployment modes, and the dangerous one

| Mode | Use | Behaviour on a conflict |
| --- | --- | --- |
| `symlink` | almost everything | refuses to overwrite an existing file |
| `symlink-each` | a directory that must stay real | per-file links |
| `copy` | files a tool rewrites in place | replaces |
| `template` | per-machine variants | **destroys a pre-existing real file, silently** |

The four `symlink-each` entries (`~/.claude/{commands,skills,agents}`,
`~/.git-template/hooks`) add `manifest = "git"`: mise walks `git ls-files` in the source instead
of the filesystem, so the repo's index — and behind it `.gitignore` — decides what deploys.
Untracked files under `home/.claude/` are then neither committed nor deployed, which is the
`/home/.claude/*` ignore block's defense-in-depth applied to the deploy side, and the `.gitkeep`
in each empty directory is what keeps the source directory existing at all. The price is that
`git ls-files` becomes a hard dependency of the **whole** apply: no `.git`, or a `~/.gitconfig`
git refuses to parse, and nothing deploys — see behaviour #34 and troubleshooting.

Template mode is the single most dangerous thing in the repo: it replaces the target with no error
and no backup. `install.sh` moves conflicting real targets aside to `<file>.pre-mise.bak` before
the first apply, keyed on `mise bootstrap dotfiles status --json` reporting `differs` —
deliberately *not* filtered by mode, since the mode that needs it most is the one that doesn't
complain.

Template gating must guard against an unconfigured machine:

```jinja
{% if mise_env is defined and "laptop" in mise_env %}
```

`mise_env` is **undefined**, not empty, when `env = []` — and a template that fails to render
aborts the entire apply, taking unrelated symlink entries with it.

**Sensitive directories are never whole-directory symlinks** (`~/.gnupg`, `~/.config/gh`,
`~/.claude`, `~/.ssh`) so live tokens and keys cannot land in the repo tree. Their *mode* is a
fifth kind of entry: `"~/.gnupg" = { permissions = "0700" }` and the same for `~/.ssh` — no
source, no content, mise only chmods what exists (≥ 2026.9.13). mise would otherwise create
them at the process umask, and gpg and ssh both refuse a too-permissive directory. These run in
every path that applies dotfiles and report drift in `mise bootstrap status`, which neither a
chmod hook (silent repair) nor `[bootstrap.directories]` (skipped by `--only dotfiles` and a
standalone `dotfiles apply`) managed alone; the repo used both until 2026-09. What remains of
the hook is `mkdir -p -m 700 ~/.ssh`, because a permissions entry never creates its target and
warns on every apply when it is absent.

The trap they bring: a drifted mode reports `state: differs`, the very state `install.sh` and
`setup:custom-hookup` back up by moving the target aside. Both skip `mode: "permissions"`, and
`scripts/dotfiles-targets.py` never lists such an entry — otherwise a 0775 `~/.ssh` would be
moved to `~/.ssh.pre-mise.bak`, keys and all. Anything new that acts on `differs` must do the
same; CI plants a 0775 `~/.ssh` to hold that line.

---

## 7. Removal reads the live config, so order matters

mise records `symlink-each` links under `$MISE_STATE_DIR/dotfiles` and offers `mise bootstrap
dotfiles unapply`, but it reads the **live config** to decide what an entry owns — so it helps
only while the entry still exists. The order that works is unapply, *then* delete the entry.

Removing the entry first leaves its symlink and nothing reports it. `mise run cleanup` is the
reaper for that case, and it is deliberately narrow: it removes only links that are **both**
dangling **and** pointing into this repo.

A deselected **profile** is the case the live-config rule favours: its `config.<profile>.toml`
is still on disk and still linked, so `mise bootstrap unapply <profile>` (≥ 2026.9.13) can
remove the dotfiles, managed files, directories and user services it declared, plus any empty
parent directory mise made for them — keeping anything a selected config still declares, and
any target changed since it was applied. `setup:profiles` previews that and offers it for the
profiles just removed, and only for those: unapply removes an env's resources even while the
env is still selected. Packages, repos, tools and whatever a profile's *tasks* installed are
out of its scope.

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
- it may carry settings as `[env]`, but never a target under `~/.config/mise/`, which only this
  repo's `config.toml` manages. A per-profile value is a `mise_env` condition in the value, and
  it renders `""` (not unset) where it does not match (`mise_behaviours.md` 47)

`setup:custom-hookup` removes the drop-in link again if the live lint fails, so a broken
companion cannot take the main repo down. It also `mise trust`s the drop-in itself. On 2026.7.x
an untrusted `conf.d` file was *silently ignored*, which would have hidden the whole companion;
on 2026.9.15 a never-trusted global drop-in loads anyway, so the call is insurance now.

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
- **`mise doctor project`** — the `[doctor.checks]` in `mise/config.toml` (and the graphical,
  cosmic and neovim profile files): read-only probes for the failure modes mise is quiet about
  (a corrupt `~/.gitconfig`, a dirty clone, dotfile drift, a too-old mise, the login shell).
  Machine state, not repo state, so it is not part of `repo:lint`; CI's e2e job runs it on the
  converged container.

Two rules that come from bugs testing alone missed: **run everything twice**, and for anything
privileged, **stub `sudo`/`apt-get`/`curl` on `PATH` and assert on the logged command lines**
rather than executing them.
