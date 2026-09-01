# .dotfiles-mise

## Overview

Declarative dotfiles and machine setup built on [`mise bootstrap`](https://mise.jdx.dev/bootstrap.html)
(mise ≥ 2026.8.16). A machine opts into capability **profiles**; everything mise can declare is
declared, and the small remainder that it cannot lives in a chain of file tasks.

Successor to the Stow-based `~/.dotfiles` (retired 2026-07-26). That repo is an archive; the
only thing worth going back for is the reasoning behind a ported behaviour.

**Targets Ubuntu 24.04+ / glibc ≥ 2.39**, Debian-family (Ubuntu / Pop!_OS / Mint). The floor
comes from the `neovim` profile's prebuilt `tree-sitter` — see `README.md`.

## Tech stack

| Component | Purpose |
| --- | --- |
| **mise** | tool versions, system packages, git repos, dotfiles, task runner — all of it |
| **`[dotfiles]`** | symlink/copy/template deployment from `home/` and `templates/` |
| **`[bootstrap.packages]`** | apt system packages |
| **`[bootstrap.repos]`** | git clones (oh-my-zsh, plugins, p10k, oh-my-tmux, PathPicker) |
| **`[tasks.bootstrap]`** | the imperative tail: the machine state mise can't declare |
| **Zsh** | login shell, oh-my-zsh + Powerlevel10k |
| **Runtimes** | rust, go, node, zig via mise `[tools]` |

## Project structure

```
install.sh          the only imperative pre-mise step; safe to re-run
mise/
  config.toml       core: settings, tools, packages, repos, hooks, [tasks.bootstrap], dotfiles
  config.<p>.toml   one per profile — ADDs capability, never redeclares a core key
  miserc.example.toml   the profile menu (machine copies it to ~/.config/mise/miserc.toml)
  tasks/            file tasks; tasks/lib/*.sh are shared helpers (mode 644, see below)
home/               mirrors $HOME — the dotfiles.root for sourceless [dotfiles] entries
templates/          template-mode sources ({% if mise_env is defined and "laptop" in mise_env %})
sandbox/mkhome.sh   throwaway-$HOME verification harness
scripts/lint-config.py   the config lint CI runs
vendor/             pristine upstream snapshots (merge base for update:tmux-local)
docs/fetch.sh       populates docs/upstream/ — run it after cloning
docs/upstream/      vendored mise docs (NOT committed; absent until fetched)
```

Per-machine state lives **outside** the repo, in a real `~/.config/mise/` directory:
`miserc.toml` (this machine's profiles), `conf.d/*.toml` (drop-ins, including the private
companion repo's), and optionally `config.local.toml`. Nothing machine-specific is committed.

## Quick start

```bash
git clone https://github.com/bassemkaroui/.dotfiles-mise.git ~/.dotfiles-mise
~/.dotfiles-mise/install.sh
```

The clone **must** live at `~/.dotfiles-mise` and use the default `~/.config`: `mise/config.toml`
names both literally, and `install.sh` refuses rather than half-deploy. After the first run,
`mise bootstrap` and `mise bootstrap dotfiles apply` work from any directory with no environment
variables.

## Essential commands

| Task | Command |
| --- | --- |
| Full setup / re-converge | `mise bootstrap --yes` |
| What's out of sync | `mise bootstrap status` |
| Every declarative resource, in dependency order | `mise bootstrap plan` (`--detailed-exitcode`: 0 converged, 2 pending, 1 unknown) |
| Just the dotfiles | `mise bootstrap dotfiles status` / `mise bootstrap dotfiles apply --dry-run` |
| What would change, current vs desired, per entry | `mise bootstrap dotfiles diff` |
| Remove an entry (in this order) | `mise bootstrap dotfiles unapply <target>` **first**, then delete the entry |
| Recapture a file edited in place | `mise bootstrap dotfiles add ~/.p10k.zsh` |
| Add/remove this machine's profiles | `mise run setup:profiles` (space toggles; `--list` to print) |
| Cloned-repo drift | `mise bootstrap repos status` |
| Reap links left by removed entries | `mise run cleanup --dry-run` |
| **Everything CI runs, before you push** | **`mise run repo:lint`** |
| Config collision lint only | `python3 scripts/lint-config.py` (`--live` for `~/.config/mise`) |
| Throwaway-`$HOME` verification | `sandbox/mkhome.sh` |
| **Fetch the upstream mise docs** (do this first on a fresh clone) | **`docs/fetch.sh`** |
| Fold upstream oh-my-tmux changes in | `mise run update:tmux-local` |
| Update unpinned clones | `mise run update:repos` |
| List every task | `mise tasks` |

## Key patterns

- **Profiles, not detection.** `~/.config/mise/miserc.toml`'s `env = [...]` sets `$MISE_ENV`,
  which selects `config.<profile>.toml` files and gates tasks via `require_profile`. Listing a
  profile *is* the consent — there are no capability prompts and no auto-detection files.
- **One key, one file.** mise's same-key precedence across sibling global configs is
  inconsistent, so no `[dotfiles]` target, repo path, tool, var or task may be declared twice.
  `scripts/lint-config.py` enforces it.
- **mise's own config is self-managed.** `mise/config.toml` declares the `[dotfiles]` entries
  that link itself and its profile siblings into `~/.config/mise/`, which stays a **real
  directory**. Adding a profile file and running `mise bootstrap dotfiles apply` links it.
- **The chain aborts on failure, so order is policy.** A `{ task = "x" }` member of
  `[tasks.bootstrap].run` that exits non-zero kills every later member. Essential steps run
  first; optional installs run last; anything environmental uses `skip` (warn + exit 0).
- **Optional installs are tasks, never `[bootstrap.packages]`.** A package apt cannot resolve
  fails the whole packages step at step 2 — before dotfiles, tools and the tail.
- **Upgrades are opt-in.** First install is unattended; replacing an installed app's binary
  needs `--update`. A routine bootstrap never swaps a running program underneath you.
- **`mise dotfiles ...` is deprecated; write `mise bootstrap dotfiles ...`.** The old spelling
  still works on 2026.8.16 (no runtime warning — only `--help` says so), but every call site in
  this repo uses the new one.
- **Removal is unapply-first.** `unapply` reads the **live** config, so deleting the entry first
  leaves it nothing to unapply: the links survive with their sources intact, which means they are
  not dangling and `mise run cleanup` cannot see them either. mise does prune a `symlink-each`
  link by itself when the *source file* goes away — that half is handled.
- **Never `git config --global`.** `~/.gitconfig` is a symlink into this repo and
  `git config --global` follows it, writing into the working tree. Identity goes in
  `~/.gitconfig.identity` (companion repo), signing in `~/.gitconfig.local`.
- **Never `--force` / `--force-dotfiles`.** mise suggests it on conflicts; on the
  self-management entries it overwrites the repo's own config with symlink loops.
- **Private data lives in a companion repo** (`~/.dotfiles-custom-mise`), linked in as a
  `conf.d` drop-in. Contract: `CUSTOM.md`.

Details and the evidence behind each: `.claude/docs/architectural_patterns.md`.

## Additional documentation

- [Architectural patterns](.claude/docs/architectural_patterns.md) — profiles, self-management,
  the task chain, deployment modes, the companion repo
- [mise behaviours](.claude/docs/mise_behaviours.md) — **read before designing anything**:
  sandbox-verified quirks that constrain this repo, with the traps spelled out
- [Task reference](.claude/docs/task_reference.md) — every task, what it owns, when it runs
- [Troubleshooting](.claude/docs/troubleshooting.md) — the failure modes real machines hit
- [README.md](README.md) — user-facing overview and the profile table
- [CUSTOM.md](CUSTOM.md) — the private companion repo contract
- [MIGRATION.md](MIGRATION.md) — capability map and cutover checklist from the old repo

## Working with Claude

**Before starting any non-trivial task**, create a task list with `TaskCreate` and keep it
current (`in_progress` when you start, `completed` when done).

**Read before you design.** This feature set is newer than any model's training data, so do not
design or debug from recall.

The upstream mise documentation is vendored at `docs/upstream/`, but it is **gitignored and not
committed — on a fresh clone that directory does not exist**. Populate it first:

```bash
docs/fetch.sh                      # or: MISE_DOCS_REF=v2026.8.16 docs/fetch.sh
```

Pin `MISE_DOCS_REF` to the tag matching the installed mise (`mise --version`) when you need the
docs to describe exactly the behaviour you are verifying against; it defaults to `main`, which
may already be ahead of the machine. Re-run it on a version bump.

The pages worth reading before touching config: `bootstrap.md`, `dotfiles.md`, `configuration.md`,
`configuration/environments.md`, `configuration/settings.md`, `templates.md`,
`tasks/task-configuration.md`, `bootstrap/{repos,shell,user,systemd}.md` and
`bootstrap/packages/{index,apt,plugins}.md`. The 2026.8.x resource sections have their own pages —
`bootstrap/{files,accounts,services,firewall,compose,secrets,remote}.md` — of which
`files.md` and `accounts.md` are the two this repo actually uses.

**`mise <cmd> --help` on the installed binary is authoritative where the docs and the behaviour
disagree** — and they have disagreed, more than once (documented subcommands that don't exist,
settings that are silently capped). `.claude/docs/mise_behaviours.md` is the accumulated record
of those disagreements; read it before designing anything.

**Never test against the real `$HOME`.** Use `sandbox/mkhome.sh`, or stub `sudo`/`apt-get`/`curl`
on `PATH` for anything privileged. A hand-rolled sandbox must live under `/tmp` — mise resolves
`<ancestor>/.config/mise/config.toml` from the cwd regardless of `$HOME`, so a fake home under
the real one is silently contaminated by the machine's own config.

**Run it twice.** Idempotency bugs are invisible on a single run.

**Before committing or pushing anything, run `mise run repo:lint`.** It runs the config lint
(repo and `--live`), python syntax, ruff, `shellcheck --severity=warning`, `shfmt -i 4 -ci -bn`,
`bash -n` and `zsh -n` against the same file set as `.github/workflows/ci.yml`, so passing
locally means passing in CI. **Never push without a clean run.** If a lint objects to a message
containing literal tokens (a `~/...` meant as display text), suppress it with an inline
`# shellcheck disable=<code>` naming the rule and saying why — don't rewrite the message.

**Commit straight to `main`. Never create a branch unless you are explicitly told to.** This is a
single-maintainer dotfiles repo with no PR workflow, so a feature branch is pure friction — it
has to be merged and deleted again before anything is usable. The default "branch before
committing to the default branch" habit does not apply here. Still commit only when asked, and
still never push without a clean `mise run repo:lint`.

**Adding a profile** means five touchpoints, not one: `mise/config.<name>.toml` (only if it
declares something — a task-only profile like `veracrypt` needs no file), `KNOWN_PROFILES` in
`install.sh` (the lint fails otherwise, and `install.sh` would silently drop the name), the list
in `mise/miserc.example.toml`, the README profile table, and ideally a CI sandbox matrix arm.

**Always include a final task: "Update docs if needed."** When you reach it, consider whether
the change affects `CLAUDE.md`, `.claude/docs/*`, `README.md`, `CUSTOM.md` or `MIGRATION.md`.
**Ask before modifying any documentation file.** Do not update docs silently.
