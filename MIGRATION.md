# Migration: `~/.dotfiles` (Stow + tasks) → `~/.dotfiles-mise` (mise bootstrap)

Working document. Cutover checklist at the bottom is the only part end users need.

## Capability map (old → new)

| Old | New | Phase |
|---|---|---|
| `mise run init` + `bootstrap` task chain | `install.sh` → `mise bootstrap` | 0–3 |
| Stow packages `bash zsh p10k` | `[dotfiles]` core entries | 1 |
| Stow packages `fzf bat tmux gh gh-dash claude ghostty ruff hunk gpg yazi nvim` | `[dotfiles]` core/profile entries | 2 |
| Stow package `gnome_themes` (+DE auto-exclude) | `gnome` profile `[dotfiles]` | 4 |
| Stow package `mise` (nested stow) | self-managed `[dotfiles]` entries in `mise/config.toml` link `config*.toml` + `tasks` into a real `~/.config/mise/` | 0, 1.5 |
| conf.d tool groups (`runtime cli dev ai yazi neovim`) | core `[tools]` + profile files | 1–2 |
| `.device-tag`/`.graphical-env`/`.desktop-env`/`.stow-exclude`/`.mise-conf-exclude`/`.install-exclude` + `setup:{device-tag,exclude,mise-conf-exclude,install-exclude}` | `mise/miserc.toml` profiles | 0 |
| tag-default→tag-X fallback | template-mode entries on `mise_env` | 2 |
| oh-my-zsh installer, plugin/p10k/fzf-tab clones (`setup:zsh`, `setup:shell-tools`) | `[bootstrap.repos]` | 1 |
| oh-my-tmux + nvim git **submodules** | `[bootstrap.repos]` (real clones at live paths) | 2 |
| `install:pathpicker` | `[bootstrap.repos]` + symlink task | 2–3 |
| `install:build-deps`, `install:nala`, zsh install | `[bootstrap.packages]` apt entries | 1 |
| `install:media-tools` | `media` profile apt entries (ubi fallback dropped) | 2 |
| chsh/usermod cascade (`setup:zsh` Phase 2) | `[bootstrap.user].login_shell` + NSS fallback task | 1, 3 |
| `.zshrc` block injection (`setup:zsh-config`, `setup:shell-tools`) | baked into committed `.zshrc` w/ runtime guards | 1 |
| `install:ghostty`, `install:obsidian`, `install:veracrypt` | ported tasks, profile-gated (`graphical`, `veracrypt`) | 3 |
| fonts + terminal fonts (inside `setup:zsh`) | `setup:fonts` task (`graphical`) | 3 |
| `setup:completions`, `setup:git-signing`, hostname prompt | ported tasks in `[tasks.bootstrap]` | 3 |
| `install:gnome-extensions`, `update:gnome-extensions` | `gnome` profile tasks | 4 |
| `setup:cosmic*` | `cosmic` profile tasks | 4 |
| `gpg:*` suite | ported near-verbatim | 5 |
| `update:submodules` + submodule-freshness workflow | `update:repos` task + workflow | 5 |
| `update:obsidian` | ported | 5 |
| `lint` (shellcheck/shfmt) | ported + `lint-config` collision lint | 0, 5 |
| p10k wizard lifecycle (`setup:p10k-configure`, `sync_custom_p10k`) | run wizard → `mise dotfiles add ~/.p10k.zsh` | 5 (docs) |
| `~/.dotfiles-custom` + `setup:custom-dotfiles` | custom repo v2: `conf.d/50-custom.toml` drop-in | 6 |
| `setup:git-signing` data (`~/.gitconfig.local.example` from custom repo) | stays in custom repo (privacy) | 6 |
| Public-mirror sanitize workflow | TBD (ask user) | 6 |

### Consciously dropped (user-approved 2026-07-19)
- dnf/pacman support; stow & zsh source-build fallbacks; nala *as installer* (still installed
  for interactive use); ubi static ffmpeg/imagemagick fallback for no-sudo machines.
- VeraCrypt default-on → opt-in profile.
- Fine-grained `.install-exclude` axis (obsidian/ghostty/veracrypt/pathpicker individually) —
  granularity is now per-profile.

### Known mise limitations we compensate for
- No removal semantics in `[dotfiles]` → `mise run cleanup` + this doc. Renaming or deleting a
  `config.<profile>.toml` leaves a dangling link in `~/.config/mise` that nothing reports
  (`config ls`, `dotfiles status` and `doctor` all stay silent) while that profile quietly
  stops applying — run `mise run cleanup` after any such change.
- `--force` is never safe here: on the self-management entries it replaces the repo's own
  config files with symlink loops and silently drops the global config. `install.sh` moves
  conflicting files aside instead.
- Files in `~/.config/mise` lose implicit trust while `MISE_GLOBAL_CONFIG_FILE` points at the
  repo (first run only), so `install.sh` trusts each of them individually — trusting the
  directory is not enough.
- Sibling-config precedence inconsistent → one-key-one-file rule + `scripts/lint-config.py`.
- `$MISE_ENV` invisible to hooks → all profile gating happens in tasks.
- `--force-dotfiles` replaces without backup → cutover always unstows via the old repo first.

## Cutover checklist (per machine — manual, run by a human)

1. `cd ~/.dotfiles && git pull` — make sure the old repo is current, commit any local changes.
2. Back up (`-h` dereferences the stow symlinks so the archive stores real content, not
   dangling links):
   `tar czhf ~/dotfiles-backup-$(date +%F).tgz ~/.zshrc ~/.zshenv ~/.zprofile ~/.bashrc ~/.p10k.zsh ~/.config/{mise,tmux,bat,fzf,yazi,gh,gh-dash,ghostty,ruff,hunk} ~/.gnupg/gpg-agent.conf 2>/dev/null`
3. Unstow everything with the OLD repo (restores its `.bak` backups):
   for each deployed package: `stow -D -d ~/.dotfiles/<pkg> -t ~ tag-default` (or the tag in
   `.device-tag`). The `mise` package last.
4. `git clone https://github.com/bassemkaroui/.dotfiles-mise.git ~/.dotfiles-mise`
5. `DOTFILES_PROFILES=<your profiles> ~/.dotfiles-mise/install.sh`
   — install.sh moves any conflicting real files (restored stow backups, skel rc files) aside
   to `<file>.pre-mise.bak` before applying; it never uses `--force-dotfiles`.
   **Always upgrade through `install.sh`, not a bare `mise bootstrap`** — it owns the
   `~/.config/mise` conversion, the trust fix-ups, and the conflict backups.
6. Recreate this machine's local overlays — the old repo carried some machine-specific lines
   in committed files; they now belong in gitignored local files:
   - `~/.zshrc.local`: extra PATH entries (`/usr/share/code/bin`, `/usr/local/go/bin`),
     vagrant completion fpath, java stanzas, work tooling.
   - `~/.zshenv.local` / `~/.bashrc.local`: anything else machine-specific.
7. Verify: `mise bootstrap status --missing` exits 0; open a new shell; run `mise doctor`.
8. Wire the custom repo (Phase 6 docs) and re-run `mise bootstrap --yes`.
9. Old state files (`.device-tag` etc.) stay in the old clone; the old repo remains usable as
   an archive (gpg backups history, etc.). Do not delete it until comfortable.
