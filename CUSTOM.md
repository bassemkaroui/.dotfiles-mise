# The companion repo — private config that must not live here

This repo is meant to be shareable. Some configuration is not: git identity, ssh
host names and ports, work tooling, a machine's extension manifest. Those live in
a second, private repo that this one *loads* but never contains.

The companion is **data, not a program**. It ships no installer, no tasks and no
bootstrap logic — just files plus one small config file that says where they go.

```
~/.dotfiles-custom-mise/
├── mise/config.custom.toml   # [dotfiles] entries, explicit absolute sources
├── home/                     # the private files those entries point at
└── templates/                # *.tmpl sources for template-mode entries
```

## How it is wired

`mise/config.custom.toml` is symlinked to `~/.config/mise/conf.d/50-custom.toml`,
where mise loads it alongside this repo's config **once it is trusted**. That
last part is not a formality: an untrusted drop-in is *silently ignored* — no
prompt, no error, `mise dotfiles status` exits 0 and simply does not list its
entries — so the companion would look wired up and deploy nothing. Both entry
points below run `mise trust` on it. Two things create the link, deliberately:

| Where | When | Why both |
|---|---|---|
| `install.sh` (step 4b) | the clone already exists | so the companion's entries are visible to the collision lint, the old-repo guard and the **conflict backup**, all of which run before `mise bootstrap` |
| `setup:custom-hookup` | inside `[tasks.bootstrap]`, step 12 | the fresh machine, where the companion is *cloned by that task* — long after `install.sh` has finished. It repeats the trust, lint and backup work for the same reason |

`setup:custom-hookup` also clones the companion when it is missing, deriving the
URL from this repo's `origin` by naming convention
(`…/.dotfiles-mise.git` → `…/.dotfiles-custom-mise.git`), or from
`$DOTFILES_CUSTOM_MISE_URL`. A failed clone is an info line, never an error —
most people using this repo will not have one.

## The four rules

Each of these is a way to break **every** machine, not just the companion:

1. **Every entry declares an explicit, absolute `source`.** A relative source in
   a `conf.d` drop-in resolves against `~/.config/mise/conf.d/`, not against the
   companion; a *sourceless* entry mirrors this repo's `dotfiles.root` and would
   silently look for the file in `~/.dotfiles-mise/home/`.
2. **Never declare `settings.dotfiles.root`, and never declare a key this repo
   declares.** Precedence between sibling configs is undefined — the loser is
   silent and arbitrary. `scripts/lint-config.py --live` enforces this; both
   `install.sh` and `setup:custom-hookup` run it, and the task *removes the link
   again* if it fails.
3. **Every source must exist whenever the config file is loaded.** A missing
   explicit source aborts the **entire** `dotfiles apply` — this repo's entries
   included, machine-wide. The reverse is harmless: if the companion clone is
   deleted outright, mise just omits the dangling drop-in and everything else
   applies. The dangerous state is *drop-in present, source missing*.
4. **The clone must live at `~/.dotfiles-custom-mise`.** `source` is **not**
   templated (`{{ env.X }}` is used as a literal path segment — verified), so
   the absolute paths inside `config.custom.toml` cannot follow the clone
   elsewhere. `$DOTFILES_CUSTOM_MISE_DIR` moves where the *task* looks; it does
   not rewrite the sources, so a non-default location needs those paths edited
   to match.

No `[tools]`, `[bootstrap.*]` or `[tasks]` in the companion: those belong here,
where they are linted and reviewed.

## Adding a file

```bash
cp ~/.config/something/private.toml ~/.dotfiles-custom-mise/home/.config/something/private.toml
$EDITOR ~/.dotfiles-custom-mise/mise/config.custom.toml   # one line
mise run setup:custom-hookup
```

That is the whole workflow. The old repo needed a `setup:custom-dotfiles` task,
tag directories and an INI tracker (`.custom-packages`) to do this; all of that
was stow bookkeeping and is gone.

## Device variants

A file that differs per machine is **one** template branching on the profiles in
`~/.config/mise/miserc.toml` — the replacement for the old `tag-laptop` /
`tag-desktop` directories:

```toml
"~/.ssh/config" = { source = "~/.dotfiles-custom-mise/templates/ssh_config.tmpl", mode = "template" }
```

```jinja
{% if mise_env is defined and "laptop" in mise_env %}
…laptop hosts…
{% elif mise_env is defined and "desktop" in mise_env %}
…desktop hosts…
{% else %}
…the tag-default equivalent…
{% endif %}
```

**The `mise_env is defined` guard is mandatory, not decoration.** On a machine
that selected no profiles — `env = []`, the shipped default — `mise_env` is
*undefined*, not an empty array, and `"laptop" in mise_env` on undefined is a
hard render error (`` `in` cannot be used on a container of type `undefined` ``).
A template that fails to render aborts the **entire** `mise dotfiles apply` —
every other dotfile with it, machine-wide (verified 2026-07-22). Guard every
`in mise_env` test.

`templates/ssh_config.tmpl.example` in this repo documents the mechanism.

> **Template mode overwrites a pre-existing real file silently** — no error, no
> backup, where `mode = "symlink"` refuses. Both entry points therefore back up
> first, keyed on `config.custom.toml`'s own target list (via
> `scripts/dotfiles-targets.py`) rather than on `mise dotfiles status`, whose
> view of a just-created drop-in proved unreliable. **If that list cannot be
> read — no `python3`, or Python < 3.11 without `tomli` — neither entry point
> applies anything at all**: an unprotected apply is worse than an unapplied
> companion.
>
> `chmod 600` on the template is necessary but *not sufficient*: git records
> only the executable bit, so a template committed 0600 arrives from a clone at
> 0664 and the rendered file inherits that. `setup:custom-hookup` enforces 0700
> on `~/.ssh` and 0600 on the files in it after applying.

## Your git identity goes here, not in `git config --global`

Name and email live in `~/.gitconfig.identity` — a file this companion repo
owns and deploys — pulled into your config by an `[include]` at the end of the
main repo's `~/.gitconfig`. Set them by editing that file:

```toml
# ~/.dotfiles-custom-mise/home/.gitconfig.identity
[user]
	name = Your Name
	email = you@example.com
```

then `mise run setup:custom-hookup` (or just `mise dotfiles apply`).

**Do not use `git config --global user.email …` on these machines.** The main
repo's `~/.gitconfig` is deployed as a symlink, and `git config --global`
follows the symlink and writes into the (public) repo working tree — the
`[include]` does *not* redirect that write, because includes affect only how
git *reads* config, never where it *writes* (`--global` always targets
`~/.gitconfig` itself). Keeping identity in `~/.gitconfig.identity` sidesteps
the whole problem: it never touches the public file. Signing config works the
same way through `~/.gitconfig.local` (written by `setup:git-signing`).

## If you don't have a companion repo

Nothing to do. Every machine works without one: `~/.gitconfig` ends with
`[include]`s that git ignores when the files are absent, and
`setup:custom-hookup` prints one line and exits 0.
