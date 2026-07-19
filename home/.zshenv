export MISE_TRUSTED_CONFIG_PATHS="$HOME/.config/mise"

[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Machine-local additions (never committed)
[ -f "$HOME/.zshenv.local" ] && . "$HOME/.zshenv.local"
