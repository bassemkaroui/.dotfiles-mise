# Migration: `~/.dotfiles` (Stow + tasks) → `~/.dotfiles-mise` (mise bootstrap)

Working document. Cutover checklist at the bottom is the only part end users need.

## Capability map (old → new)

| Old | New | Phase |
|---|---|---|
| ~~`mise run init` + `bootstrap` task chain~~ ✅ | `install.sh` → `mise bootstrap` → `[tasks.bootstrap]` | 0–3 |
| ~~Stow packages `bash zsh p10k`~~ ✅ | `[dotfiles]` core entries | 1 |
| ~~Stow packages `fzf bat tmux gh gh-dash claude ruff hunk gpg yazi`~~ ✅ | `[dotfiles]` core entries (+ `yazi` profile) | 2 |
| ~~Stow package `ghostty` (config only)~~ ✅ | `graphical` profile `[dotfiles]` | 2 |
| ~~Stow package `nvim`~~ ✅ | `neovim` profile `[bootstrap.repos]` | 1 |
| ~~Stow package `gnome_themes` (+DE auto-exclude)~~ ✅ | `gnome` profile `[dotfiles]` (`home/.themes/`) | 4 |
| ~~Stow package `mise` (nested stow)~~ ✅ | self-managed `[dotfiles]` entries in `mise/config.toml` link `config*.toml` + `tasks` into a real `~/.config/mise/` | 0, 1.5 |
| ~~conf.d tool groups (`runtime cli dev ai yazi neovim`)~~ ✅ | core `[tools]` + profile files | 1–2 |
| ~~`.device-tag`/`.graphical-env`/`.desktop-env`/`.stow-exclude`/`.mise-conf-exclude`/`.install-exclude` + their picker tasks~~ ✅ | `mise/miserc.toml` profiles | 0 |
| ~~tag-default→tag-X fallback~~ ✅ | template-mode entries on `mise_env`; the companion's `ssh/tag-{laptop,desktop}` is now ONE template | 2, 6 |
| ~~oh-my-zsh installer, plugin/p10k/fzf-tab clones~~ ✅ | `[bootstrap.repos]` | 1 |
| ~~oh-my-tmux + nvim git **submodules**~~ ✅ | `[bootstrap.repos]` (real clones at live paths) | 2 |
| ~~`install:pathpicker`~~ ✅ | `[bootstrap.repos]` + `setup:repo-links` task | 2–3 |
| ~~`setup:nodes-tools` (corepack enable)~~ ✅ | `post-tools` hook, guarded on `command -v corepack` | 3a |
| ~~`setup:p10k-icon` (writes `~/.p10k.local.zsh`)~~ ✅ | ported, with a shortlist menu + `--icon`/`--show`/`--clear`; asks at most once per machine | 6 |
| ~~Custom repo's `p10k/tag-desktop/.p10k.zsh`~~ ✅ | **dropped** — it differed from the shared config by exactly one line (the OS icon), which `setup:p10k-icon` now writes into the machine-local overlay. Removes the two-repos-one-key hazard | 6 |
| ~~`install:build-deps`, `install:nala`, zsh install~~ ✅ (narrowed — see below) | `[bootstrap.packages]` apt entries | 1 |
| ~~`install:media-tools`~~ ✅ | `media` profile apt entries (ubi fallback dropped) | 2 |
| ~~chsh/usermod cascade (`setup:zsh` Phase 2)~~ ✅ | `setup:login-shell-fallback` alone — there is deliberately **no `[bootstrap.user]`** section (its bare `chsh` fails unattended and aborts the whole tail) | 3a |
| ~~`.zshrc` block injection (`setup:zsh-config`, `setup:shell-tools`)~~ ✅ | baked into committed `.zshrc` w/ runtime guards | 1 |
| ~~`install:ghostty`, `install:obsidian`, `install:veracrypt`~~ ✅ | ported tasks, profile-gated (`graphical`, `veracrypt`) | 3b |
| ~~fonts + terminal fonts (inside `setup:zsh`)~~ ✅ | `setup:fonts` task (`graphical`) | 3b |
| ~~`setup:completions`, `setup:git-signing`~~ ✅ | ported tasks in `[tasks.bootstrap]` | 3a |
| ~~`setup:zsh` Phase 2 rungs 1/3/4 (sudo chsh, sudo usermod, `exec zsh`)~~ ✅ | `setup:login-shell-fallback` — mise's `[bootstrap.user]` only runs bare `chsh -s` | 3a |
| hostname prompt (`setup:zsh` Phase 6) | dropped — see below | 3a |
| ~~`install:gnome-extensions`, `update:gnome-extensions`~~ ✅ | `gnome` profile tasks (manifest still supplied by the custom repo) | 4 |
| ~~`setup:cosmic*`~~ ✅ | `cosmic` profile tasks (theme picker is manual, not chained) | 4 |
| ~~`gpg:*` suite~~ ✅ | ported; every mutating path gained a preview/confirm and a pre-import keyring backup | 5 |
| ~~`update:submodules` + submodule-freshness workflow~~ ✅ | `update:repos` task + `scripts/check-repos.py` + a monthly *notifier* workflow (there is no committed pointer left to bump, so the old PR shape does not transfer) | 5 |
| ~~`update:obsidian`~~ ✅ | ported (`--check`); `install:obsidian` reports, `update:obsidian` installs | 5 |
| ~~`lint` (shellcheck/shfmt)~~ ✅ | `repo:lint` — namespaced, and widened to config lint + shellcheck + shfmt + `bash -n`/`zsh -n`; CI calls the task rather than re-deriving the file set | 0, 5 |
| ~~p10k wizard lifecycle (`setup:p10k-configure`, `sync_custom_p10k`)~~ ✅ | run `p10k configure`, then `mise dotfiles add ~/.p10k.zsh` to recapture (README "Day-to-day"); the per-device icon is `setup:p10k-icon` → `~/.p10k.local.zsh` | 5 (docs) |
| ~~`~/.dotfiles-custom` + `setup:custom-dotfiles`~~ ✅ | companion repo v2 (`~/.dotfiles-custom-mise`): data only, one `conf.d/50-custom.toml` drop-in — see [CUSTOM.md](CUSTOM.md) | 6 |
| ~~git config: aliases, delta, lfs, credential helpers, `.git-completion.bash`, `.git-prompt.sh`, `.git-template/`~~ ✅ | **moved out of the custom repo** into `home/` — none of it is private | 6 |
| ~~git identity (`user.name`/`user.email`)~~ ✅ | companion repo → `~/.gitconfig.identity`, pulled in by an `[include]` | 6 |
| ~~`setup:git-signing` data (`~/.gitconfig.local.example`)~~ ✅ | stays in the companion repo (privacy) | 6 |
| Public-mirror sanitize workflow | TBD (ask user) | 6 |

### Consciously dropped (user-approved 2026-07-19)
- dnf/pacman support; stow & zsh source-build fallbacks; nala *as installer* (still installed
  for interactive use); ubi static ffmpeg/imagemagick fallback for no-sudo machines.
- VeraCrypt default-on → opt-in profile.
- Fine-grained `.install-exclude` axis (obsidian/ghostty/veracrypt/pathpicker individually) —
  granularity is now per-profile.
- **Interactive hostname prompt** (`setup:zsh` Phase 6). It asked on every bootstrap and did
  one `hostnamectl` call; it has nothing to do with dotfiles. Set the hostname with
  `sudo hostnamectl set-hostname <name>`.
- **`~/.fzf.bash`.** Shipped by the old `fzf` stow package, but nothing in either repo's
  `.bashrc` ever sourced it, and its `~/.fzf/bin` PATH block refers to an install method
  neither repo uses (fzf is a `[tools]` entry). `~/.fzf.zsh` *is* sourced by `.zshrc` and
  is kept.
- **Every interactive prompt inside the bootstrap path** (session B). The old install tasks
  asked "install X anyway?", "which method?", "persist this choice?". A chained task *can*
  prompt — it inherits the terminal when `mise bootstrap` is run from one (verified under a
  pty) — but any prompt hangs an unattended run, so the answers now come from the profile
  (consent), `--method` / `$GHOSTTY_INSTALL_METHOD`, and `--update`. `setup:cosmic-theme`
  keeps its menu but is no longer invoked by `setup:cosmic`; run it by hand.
- **`deb` as ghostty's default install method** — it is now `appimage` (user decision,
  2026-07-20). The AppImage needs no sudo, no PPA and no apt at all, so it is the only
  method that completes unattended and on a machine without root. `--method deb|source|snap`
  still work, and `apt:software-properties-common` still ships with the profile for the deb
  path.
- **Automatic upgrades of ghostty/obsidian on every bootstrap.** The old tasks prompted, and
  skipped the upgrade under `DOTFILES_NONINTERACTIVE`. Without a prompt, upgrading by
  default would swap a running app's binary whenever upstream moved, so an available
  upgrade is now *reported* and applied only with `--update`.
- **`.custom-packages` + `setup:custom-dotfiles`.** The INI tracker, the tag directories, the
  `recurse_dirs` no-fold handling and the unstow-restore path were all stow bookkeeping. Adding a
  private file is now `cp` plus one line in `mise/config.custom.toml` (CUSTOM.md), or
  `mise dotfiles add`.
- **Most of `install:build-deps`.** The old task installed `autoconf automake libtool clang
  libclang-dev nasm yasm libjpeg/png/tiff/webp/freetype/fontconfig/ltdl-dev python3-pip
  libssl-dev libevent-dev libncurses-dev perl` — a source-build toolchain for the stow and zsh
  fallbacks (both dropped, D7) and for compiling ffmpeg/imagemagick (now apt packages in the
  `media` profile). What survives is `build-essential` + `pkg-config`, which is what the `cargo:`
  backend needs. If a tool later fails to build for want of `libssl-dev` or `libclang-dev`, add
  it back to `[bootstrap.packages]` — that is the intended repair, not a regression.
- **The `busybox unzip` third-choice font extractor** (`setup:zsh` had unzip → python3 →
  busybox). `unzip` is a `[bootstrap.packages]` entry and python3 is required by
  `install.sh` anyway, so the third rung had no reachable audience.

### Carried over unchanged, but questionable (decide before/at cutover)

- **Ghostty** ships two files: an empty `config` and `config.ghostty` (341 B) holding every
  setting. That is not a bug — Ghostty 1.3.1 loads **both** names, with `config.ghostty`
  taking precedence on conflicting keys (verified with `ghostty +show-config` against three
  throwaway `XDG_CONFIG_HOME`s: `config.ghostty` alone works, `config` alone works, and with
  both present `config.ghostty` wins). The `.ghostty` extension is what gets the file syntax
  highlighting in editors. Both are ported verbatim.
- ~~`~/.p10k.zsh` is declared by this repo AND by the custom repo~~ **RESOLVED**: the two
  files differed by a single line, the OS icon. The companion repo drops its p10k package
  entirely and `setup:p10k-icon` writes that line into `~/.p10k.local.zsh`, which
  `home/.zshrc` sources after `~/.p10k.zsh`. Any *other* key the companion repo shares is
  still caught by `lint-config.py --live`, which `install.sh` runs.

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
  `install.sh` additionally *refuses to run* while any `[dotfiles]` target or
  `[bootstrap.repos]` path still resolves into `~/.dotfiles` **or `~/.dotfiles-custom`**
  (the companion repo is deployed by the same stow run and is just as much part of the
  rollback path — `~/.gitconfig`, `~/.ssh/config`, `~/.p10k.zsh` and the gnome-extensions
  manifest all point into it), because the old repos deploy
  whole directories (`~/.config/bat`, `~/.config/tmux`, `~/.config/yazi`, …) as symlinks —
  applying through one of those would rewrite files inside the rollback path, and mise
  replaces a *symlink* without any conflict error (to mise a symlink is never data). The
  check runs twice, before each bootstrap pass, because the profile files' entries are
  invisible during the first one; it requires `python3`, and `install.sh` refuses to continue
  without it while `~/.dotfiles` exists. `setup:repo-links` carries the same refusal, since it
  is also reachable standalone.
- **A `[dotfiles]` entry whose explicit `source` is missing aborts the entire apply**, not
  just that entry (verified 2026-07-20). So no entry may point at a path an earlier bootstrap
  step creates: `~/.config/tmux/tmux.conf` → `~/.tmux/.tmux.conf` and `~/.local/bin/fpp` are
  symlinked by the `setup:repo-links` task instead, where a missing clone is just a warning.
- **A *sourceless* entry whose mirrored source is missing is silently ignored** — it never
  deploys, never appears in `mise dotfiles status`, and `status --missing` still exits 0. A
  typo'd target is therefore invisible; `scripts/lint-config.py` checks every entry's source
  exists in the repo to compensate.
- **mise creates missing parent directories with the process umask** (0755/0775), which gpg
  rejects for `~/.gnupg`. A `pre-dotfiles` hook creates it 0700 first; re-applying does not
  change the mode afterwards.
- **`mode = "template"` overwrites a pre-existing real file silently** — no error, no backup,
  where `mode = "symlink"` refuses. `install.sh` therefore backs up every *differing* target,
  not just symlink-mode ones. This is why the cutover backup tar matters even though mise
  "shouldn't" clobber anything.
- **No `[bootstrap.user]` section, deliberately.** Its one command is a bare `chsh -s`, which
  PAM-prompts and so fails unattended — and a failing bootstrap step aborts every later step,
  including the whole `[tasks.bootstrap]` tail. `setup:login-shell-fallback` owns the login
  shell instead (sudo chsh → sudo usermod → interactive chsh → `exec zsh`).
- **A `[tasks.bootstrap]` step that exits non-zero aborts every step after it** and fails
  `mise bootstrap` with that code (verified). That shapes the whole imperative tail: the
  steps every machine needs run first, the optional installs last, and those installs treat
  anything environmental (no network, no sudo, no desktop session, no upstream asset for
  this Ubuntu release) as `warn` + `exit 0` rather than a failure.
- **`mise run cleanup` reaps only DANGLING links** — ones whose source left the repo. It
  does *not* reap links whose profile was deselected, because mise has no removal semantics
  and the source is still right there. Deselecting `gnome` leaves `~/.themes/*` behind;
  delete those by hand when switching desktops.
- **ANY untracked, non-gitignored file in ANY `[bootstrap.repos]` clone aborts the whole
  bootstrap** at the repos step (step 2 of 11) — `mise ERROR repos: ~/x has local changes`, rc=1,
  and dotfiles/tools/the task chain never run (verified 2026-07-21). This is not hypothetical:
  oh-my-zsh creates `~/.oh-my-zsh/completions/`, and generated `_tool` completion files land
  inside the plugin clones. `install.sh` pre-flights `repos status` and refuses with the offending
  paths rather than letting mise die halfway; `mise run update:repos` reports the same set. The
  cheapest fix for a generated file is `printf '<name>\n' >> <clone>/.git/info/exclude` — mise
  treats a gitignored file as clean, and `.git/info/exclude` is local to the clone.
- **Who updates a `[bootstrap.repos]` clone is the opposite of what "pinned" suggests** (verified):
  `ref = "<branch>"` means **mise** fast-forwards it on every bootstrap — and a *diverged* one
  fails the bootstrap outright — while an entry with **no `ref`** is never touched again after
  the first clone. `mise run update:repos` owns the second class (oh-my-zsh, the zsh plugins,
  p10k, fzf-tab, PathPicker) and only reports on the first.
- **`[dotfiles].source` is not templated.** `{{ env.X }}` is taken as a literal path segment,
  exactly like `[bootstrap.repos].url`. This is why the companion repo must live at
  `~/.dotfiles-custom-mise` (CUSTOM.md rule 4).
- **`dconf` exits 0 with nowhere to persist a write** (no session bus / a sandboxed HOME):
  the write silently goes nowhere. `setup:fonts` reads the value back rather than trusting
  the exit code.

## Cutover checklist (per machine — manual, run by a human)

1. `cd ~/.dotfiles && git pull` — make sure the old repo is current, commit any local changes.
2. Back up (`-h` dereferences the stow symlinks so the archive stores real content, not
   dangling links):
   `tar czhf ~/dotfiles-backup-$(date +%F).tgz ~/.zshrc ~/.zshenv ~/.zprofile ~/.bashrc ~/.bash_logout ~/.profile ~/.p10k.zsh ~/.fzf.zsh ~/.gitconfig* ~/.git-completion.bash ~/.git-prompt.sh ~/.git-template ~/.ssh/config ~/.config/{mise,tmux,bat,fzf,yazi,gh,gh-dash,ghostty,ruff,hunk,completions} ~/.claude ~/.gnupg/gpg-agent.conf ~/.local/bin/fpp ~/.themes ~/.local/share/{fonts,gnome-extensions,applications/obsidian.desktop} 2>/dev/null`
   Every one of those is a `[dotfiles]` target now, i.e. a candidate for
   `install.sh`'s move-aside. `~/.ssh/config` and `~/.gitconfig*` matter most: the first is
   deployed in **template** mode, which overwrites a real file with no error and no backup of
   its own, and the second is where your git identity lives.
3. Unstow everything with **both** old repos (this restores their `.bak` backups):
   for each deployed package: `stow -D -d ~/.dotfiles/<pkg> -t ~ tag-default` (or the tag in
   `.device-tag`). The `mise` package last. Then the companion:
   `stow -D -d ~/.dotfiles-custom/<pkg> -t ~ tag-<tag>` for `git`, `ssh`, `p10k` and
   `gnome_extensions` — `install.sh` refuses to run while anything still resolves into either
   clone.
3b. Clean the `[bootstrap.repos]` clones. `git -C ~/.oh-my-zsh status --porcelain` and the same
   for each plugin clone: any untracked file there aborts the bootstrap (see the limitations
   above). On the author's laptop this is `~/.oh-my-zsh/completions/` and generated `_helm` /
   `_kubectl` in the autosuggestions clone.
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
8. Wire the companion repo — clone it to `~/.dotfiles-custom-mise` (see [CUSTOM.md](CUSTOM.md))
   and **re-run `~/.dotfiles-mise/install.sh`**, not `mise bootstrap`. Only `install.sh` runs the
   old-repo guard, the live collision lint and the conflict backup, and the companion's
   `~/.ssh/config` entry is deployed in template mode, which replaces a real file without a
   backup of its own. (`mise run setup:custom-hookup` is the equivalent for a machine that is
   already cut over: it repeats the same backup and lint before applying.)
9. Old state files (`.device-tag` etc.) stay in the old clone; the old repo remains usable as
   an archive (gpg backups history, etc.). Do not delete it until comfortable.
