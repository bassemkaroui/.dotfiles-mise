# .dotfiles-mise

Declarative dotfiles + machine setup built on [mise bootstrap](https://mise.jdx.dev/bootstrap.html)
(mise ≥ 2026.7.7). Successor to the Stow-based [.dotfiles](https://github.com/bassemkaroui/.dotfiles)
repo — see [MIGRATION.md](MIGRATION.md) for the capability map and cutover checklist.

Targets Debian-family Linux (Ubuntu/Pop!_OS/Mint). Packages install through mise's native
`apt` manager; `nala` is installed for interactive use but automation never depends on it.

## Quick start (new machine)

```bash
git clone https://github.com/bassemkaroui/.dotfiles-mise.git ~/.dotfiles-mise
~/.dotfiles-mise/install.sh
```

The clone must live at `~/.dotfiles-mise` and use the default `~/.config` —
`mise/config.toml` names both paths literally, and `install.sh` refuses to run
otherwise rather than half-deploy.

`install.sh` does, in order:

1. Installs mise if missing (`curl https://mise.run | sh`).
2. Resolves a GitHub token (`$MISE_GITHUB_TOKEN` → `$GITHUB_TOKEN` → `$GH_TOKEN` →
   `gh auth token`) and exports it — required because installing `[tools]` hits the GitHub
   releases API, which rate-limits unauthenticated callers to 60 req/hr.
3. Prepares `~/.config/mise` as a real directory (converting a legacy whole-dir symlink, or
   backing up a pre-existing global config).
4. Seeds the per-machine `~/.config/mise/miserc.toml` (profile selection) — pass
   `DOTFILES_PROFILES=graphical,ai,dev` or answer the prompt.
5. Refuses to continue if any `[dotfiles]` target or `[bootstrap.repos]` path still resolves
   into the old `~/.dotfiles` **or `~/.dotfiles-custom`** stow deployment (unstow them first —
   see [MIGRATION.md](MIGRATION.md) step 3). Needs `python3`; override with
   `DOTFILES_OLD_REPO` / `DOTFILES_OLD_CUSTOM_REPO`.
6. `mise trust`, moves conflicting real dotfile targets aside to `<file>.pre-mise.bak`
   (e.g. the stock `~/.bashrc` on a fresh account), then runs `mise bootstrap` with
   `MISE_GLOBAL_CONFIG_FILE` pointed at the repo — the one-time nudge mise needs before its
   own config is linked into place.

Afterwards `mise bootstrap` and `mise dotfiles apply` work from **any** directory with no
environment variables: `mise/config.toml` manages itself and its profile siblings into
`~/.config/mise/` (see "Design rules").

Re-running any of it is safe — everything converges.

## Profiles

A machine opts **in** to capability groups via `~/.config/mise/miserc.toml` (machine-local,
outside the repo — `install.sh` seeds it):

```toml
env = ["graphical", "cosmic", "ai", "dev", "yazi", "neovim", "media", "laptop"]
```

| Profile | What it adds |
|---|---|
| *(core, always on)* | runtimes (rust/go/node/zig), core CLI tools, shell configs (zsh + oh-my-zsh + p10k, bash), tmux, git tooling, gpg config, login shell |
| `graphical` | Ghostty & Obsidian installs + configs, Nerd Font + terminal fonts |
| `gnome` | GTK/shell themes + GNOME Shell extensions (implies `graphical`) |
| `cosmic` | ddcutil/i2c setup; theme picker via `mise run setup:cosmic-theme` (implies `graphical`) |
| `ai` | claude + sandbox-runtime |
| `dev` | uv, corepack, pre-commit, doppler |
| `yazi` | yazi + rich preview stack |
| `neovim` | neovim + tree-sitter + personal nvim config |
| `media` | ffmpeg + imagemagick (apt) |
| `veracrypt` | VeraCrypt (console) |
| `laptop` / `desktop` | device markers consumed by template-mode dotfiles (no standalone config) |

After editing profiles: `mise bootstrap --yes` (add) — removals leave files behind by design;
run `mise run cleanup` (Phase 5) to reap stale symlinks.

## Everyday commands

```bash
mise bootstrap status            # everything: packages, repos, dotfiles, shell, tools
mise dotfiles status             # just the dotfiles
mise dotfiles apply --dry-run    # preview
mise dotfiles add ~/.p10k.zsh    # recapture a file you edited/regenerated in place
mise run setup:p10k-icon         # pick the prompt's OS icon (--show / --clear / --icon)
mise bootstrap repos status      # cloned-repo drift
mise run cleanup --dry-run       # find symlinks left behind by removed entries
python3 scripts/lint-config.py   # config collision lint (CI wiring comes in Phase 5)
python3 scripts/lint-config.py --live   # same, for machine-local ~/.config/mise files
sandbox/mkhome.sh                # run bootstrap checks against a throwaway $HOME
```

## Repo layout

```
install.sh        bootstrap entry point (the only imperative pre-mise step)
mise/             config.toml + config.<profile>.toml + tasks/ — linked file-by-file
                  into ~/.config/mise/, which stays a real directory
home/             dotfiles.root — mirrors $HOME, deployed via [dotfiles]
templates/        template-mode sources ({% if "laptop" in mise_env %}…)
sandbox/          fake-$HOME verification harness
scripts/          config collision lint
docs/upstream/    vendored mise docs (gitignored; docs/fetch.sh refreshes)
```

Per-machine state lives **outside** the repo, in the real `~/.config/mise/`:
`miserc.toml` (this machine's profiles), `conf.d/*.toml` (local drop-ins), and
`config.local.toml` if you want one. Nothing machine-specific is ever committed.

## Your own private companion repo

Anything you don't want in a shareable repo — identity, keys, host lists, work config —
goes in a second repo of your own that this one *extends itself with*. It is a plain
directory with the same shape as this one, and nothing about it is specific to the author's
setup:

```
~/.dotfiles-custom-mise/       (or $DOTFILES_CUSTOM_MISE_DIR)
├── mise/config.custom.toml    [dotfiles] entries with explicit absolute sources
└── home/                      the files those entries point at
```

`setup:custom-hookup`, a step in the `[tasks.bootstrap]` chain, **clones it if it's missing**
and links that config file to `~/.config/mise/conf.d/50-custom.toml`. The clone URL comes from
`$DOTFILES_CUSTOM_MISE_URL`, or is derived from this repo's own `origin` by naming convention
(`…/.dotfiles-mise.git` → `…/.dotfiles-custom-mise.git`) — so nothing private is committed here
and you get *your* companion, not the author's. No companion repo, no credentials, no problem:
the step says so and the bootstrap carries on.

It is a task rather than a `[bootstrap.repos]` entry on purpose: a repos clone that fails
aborts the entire bootstrap, and a private repo fails to clone on exactly the machines that
most need the rest of it (CI, a fresh box before its keys exist, anyone else using this repo).

Rules the companion repo must follow — the first is the one that bites:

- **Every entry needs an explicit `source = "~/.dotfiles-custom-mise/home/…"`.**
  `settings.dotfiles.root` belongs to this repo, and a second declaration of it lands in
  mise's undefined sibling-config precedence.
- **It may not redeclare a key this repo declares** (or define `[tasks.bootstrap]`).
  `python3 scripts/lint-config.py --live` checks exactly this — it loads this repo's keys as
  a baseline and then scans `~/.config/mise/conf.d/`, so a collision is caught rather than
  silently resolved. `install.sh` runs that pass on every install.
- **Its sources must exist whenever its config file does**, because a `[dotfiles]` entry
  with a missing explicit source aborts the *entire* apply — this repo's files included.

This repo already leaves room for the usual private pieces: `~/.gitconfig` ends with
`[include]`s for `~/.gitconfig.identity` and `~/.gitconfig.local`, and
`templates/ssh_config.tmpl.example` shows how a companion repo does per-machine variants
with template mode.

## Design rules (enforced, not aspirational)

- **One key, one file.** mise's sibling-config precedence is inconsistent (verified on
  2026.7.7), so no `[dotfiles]` target / repo path / tool / var / task may be declared in two
  config files. `scripts/lint-config.py` fails the build otherwise.
- **Hooks are unconditional.** `$MISE_ENV` does not reach `[bootstrap.hooks]` (verified) —
  profile-gated logic lives in tasks, which do see it.
- **Sensitive dirs are never whole-dir symlinks** (`~/.gnupg`, `~/.config/gh`, `~/.claude`,
  `~/.ssh`) so live tokens/keys can't land in the repo tree.
- **No `[dotfiles]` source may point at something bootstrap creates.** An entry whose explicit
  source is missing aborts the *entire* apply, and the first-run pass applies dotfiles before
  cloning repos — so links into `~/.tmux` and `~/.local/opt/PathPicker` are made by the
  `setup:repo-links` task, where a missing clone is only a warning. `scripts/lint-config.py`
  checks every entry's source exists, because mise silently ignores a missing *sourceless*
  one (it never deploys and `dotfiles status --missing` still exits 0).
- **mise's own config is self-managed.** `mise/config.toml` declares two `[dotfiles]` entries
  (absolute sources, `config*.toml` glob + `tasks`) that link the repo's config into
  `~/.config/mise/`. Adding a profile file and running `mise dotfiles apply` from anywhere
  links it. Removing one leaves a dangling link that mise reports nowhere — that's what
  `mise run cleanup` is for.
- **Never run `mise dotfiles apply --force` / `mise bootstrap --force-dotfiles`.** mise
  suggests it when it hits a conflict, but on the self-management entries it would overwrite
  the repo's own config files with symlink loops and silently drop the global config. Resolve
  conflicts by moving the offending file aside (which `install.sh` does for you).
