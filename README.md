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

`install.sh` does, in order:

1. Installs mise if missing (`curl https://mise.run | sh`).
2. Resolves a GitHub token (`$MISE_GITHUB_TOKEN` → `$GITHUB_TOKEN` → `$GH_TOKEN` →
   `gh auth token`) and exports it — required because installing `[tools]` hits the GitHub
   releases API, which rate-limits unauthenticated callers to 60 req/hr.
3. Backs up any existing `~/.config/mise` (real dir or foreign symlink) and symlinks it →
   `~/.dotfiles-mise/mise`.
4. Seeds the per-machine `mise/miserc.toml` (profile selection) from
   `mise/miserc.example.toml` — pass `DOTFILES_PROFILES=graphical,ai,dev` or answer the prompt.
5. `mise trust`, moves conflicting real dotfile targets aside to `<file>.pre-mise.bak`
   (e.g. the stock `~/.bashrc` on a fresh account), then `mise bootstrap --yes`.

Re-running any of it is safe — everything converges.

## Profiles

A machine opts **in** to capability groups via `mise/miserc.toml` (gitignored, one per machine):

```toml
env = ["graphical", "cosmic", "ai", "dev", "yazi", "neovim", "media", "laptop"]
```

| Profile | What it adds |
|---|---|
| *(core, always on)* | runtimes (rust/go/node/zig), core CLI tools, shell configs (zsh + oh-my-zsh + p10k, bash), tmux, git tooling, gpg config, login shell |
| `graphical` | Ghostty & Obsidian installs + configs, Nerd Font + terminal fonts |
| `gnome` | GNOME themes + shell extensions |
| `cosmic` | COSMIC theme + ddcutil/i2c setup |
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
mise bootstrap repos status      # cloned-repo drift
python3 scripts/lint-config.py   # config collision lint (CI wiring comes in Phase 5)
sandbox/mkhome.sh                # run bootstrap checks against a throwaway $HOME
```

## Repo layout

```
install.sh        bootstrap entry point (the only imperative pre-mise step)
mise/             becomes ~/.config/mise (dir symlink): config.toml + config.<profile>.toml
                  + tasks/ ; miserc.toml & conf.d/ are per-machine (gitignored)
home/             dotfiles.root — mirrors $HOME, deployed via [dotfiles]
templates/        template-mode sources ({% if "laptop" in mise_env %}…)
sandbox/          fake-$HOME verification harness
docs/upstream/    vendored mise docs (gitignored; docs/fetch.sh refreshes)
```

## Design rules (enforced, not aspirational)

- **One key, one file.** mise's sibling-config precedence is inconsistent (verified on
  2026.7.7), so no `[dotfiles]` target / repo path / tool / var / task may be declared in two
  config files. `scripts/lint-config.py` fails the build otherwise.
- **Hooks are unconditional.** `$MISE_ENV` does not reach `[bootstrap.hooks]` (verified) —
  profile-gated logic lives in tasks, which do see it.
- **Sensitive dirs are never whole-dir symlinks** (`~/.gnupg`, `~/.config/gh`, `~/.claude`,
  `~/.ssh`) so live tokens/keys can't land in the repo tree.
