export MISE_TRUSTED_CONFIG_PATHS="$HOME/.config/mise"

[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Machine-local additions (never committed).
# `if`, not `&&`: the last statement of an rc file sets its exit status, and
# `[ -f x ] && . x` leaves 1 behind when the file is absent. Harmless here
# (.zshrc runs afterwards for an interactive shell) but not for `zsh -c`,
# where .zshenv is the only file read — and it is the same shape as the
# .bashrc/.zshrc bug, so it should not be left as a trap for the next editor.
if [ -f "$HOME/.zshenv.local" ]; then
    . "$HOME/.zshenv.local"
fi
