# ~/.zshrc — fully owned by ~/.dotfiles-mise (deployed via mise [dotfiles]).
# Machine-specific additions go in ~/.zshrc.local (sourced at the end), never here.
#
# Every tool stanza is guarded at runtime with (( $+commands[tool] )) so this
# single file works on any profile combination — a machine without the `yazi`
# or `neovim` profile simply skips those sections.

# GPG-agent passphrase: pass the passphrase through tty on headless targets
# https://unix.stackexchange.com/questions/608842
if (( $+commands[systemctl] )) && [[ $(systemctl get-default 2>/dev/null) == "multi-user.target" ]]; then
    export GPG_TTY=$(tty)
fi

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# ── mise ──────────────────────────────────────────────────────────────────────
# mise PATH (for systems where mise is not in default PATH)
for _mise_path in "$HOME/.local/bin" "$HOME/.local/share/mise/bin"; do
    if [[ -x "$_mise_path/mise" && ":$PATH:" != *":$_mise_path:"* ]]; then
        export PATH="$_mise_path:$PATH"
        break
    fi
done
unset _mise_path

# completions (file-based: tools whose completions evolve with the tool)
COMPLETIONS_DIR="$HOME/.config/completions"
[[ -d "$COMPLETIONS_DIR" ]] || mkdir -p "$COMPLETIONS_DIR"
typeset -TUx FPATH fpath
fpath=("$COMPLETIONS_DIR" $fpath)
if [[ ! -f "$COMPLETIONS_DIR/_mise" ]]; then
    typeset -g -A _comps
    autoload -Uz _mise
    _comps[mise]=_mise
fi
if (( $+commands[mise] )); then
    { mise completions zsh >| "$COMPLETIONS_DIR/_mise"; } 2>/dev/null &|
fi
if [[ ! -f "$COMPLETIONS_DIR/_gh" ]]; then
    typeset -g -A _comps
    autoload -Uz _gh
    _comps[gh]=_gh
fi
if (( $+commands[gh] )); then
    { gh completion -s zsh >| "$COMPLETIONS_DIR/_gh"; } 2>/dev/null &|
fi
if (( $+commands[doppler] )); then
    fpath=("$HOME/.local/share/doppler/zsh/completions" $fpath)
    if [[ ! -f "$HOME/.local/share/doppler/zsh/completions/_doppler" ]]; then
        { doppler completion install --no-check-version >/dev/null 2>&1 &| }
    fi
fi

export MISE_TRUSTED_CONFIG_PATHS="$HOME/.config/mise"
(( $+commands[mise] )) && eval "$(mise activate zsh)"

# ── oh-my-zsh ─────────────────────────────────────────────────────────────────
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git fzf-tab zsh-autosuggestions zsh-syntax-highlighting sudo command-not-found aws)
[[ -f "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"
# When oh-my-zsh is absent (bare bootstrap, repos not applied yet) the compdef
# and hook helpers it normally provides don't exist — provide the minimum so
# the guarded stanzas below never error.
(( $+functions[compdef] )) || { autoload -Uz compinit && compinit; }
autoload -Uz add-zsh-hook

# ── Cache helper ──
# Caches eval output to ~/.cache/zsh/, regenerates in background if stale (>24h)
_zsh_cache_eval() {
    local name=$1; shift
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
    local cache_file="$cache_dir/$name.zsh"
    [[ -d "$cache_dir" ]] || mkdir -p "$cache_dir"
    if [[ -f "$cache_file" ]]; then
        source "$cache_file"
        if [[ -n $(find "$cache_file" -mmin +1440 2>/dev/null) ]]; then
            { eval "$*" >| "$cache_file" } 2>/dev/null &|
        fi
    else
        eval "$*" >| "$cache_file"
        source "$cache_file"
    fi
}

# ── Lazy completion helper ──
# Writes _<cmd> to $LAZY_COMPLETIONS_DIR once (in background), then relies on
# fpath autoload for future shells. To refresh after a tool upgrade:
#   rm "$LAZY_COMPLETIONS_DIR/_<cmd>"
LAZY_COMPLETIONS_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/completions"
[[ -d "$LAZY_COMPLETIONS_DIR" ]] || mkdir -p "$LAZY_COMPLETIONS_DIR"
fpath=("$LAZY_COMPLETIONS_DIR" $fpath)
_zsh_lazy_completion() {
    local cmd=$1; shift
    local target="$LAZY_COMPLETIONS_DIR/_$cmd"
    typeset -g -A _comps
    autoload -Uz "_$cmd"
    _comps[$cmd]="_$cmd"
    [[ -f "$target" ]] || { eval "$*" >| "$target" } 2>/dev/null &|
}

# ── History ──
HISTSIZE=50000
HISTFILE=~/.zsh_history
SAVEHIST=$HISTSIZE
HISTDUP=erase
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# ── Completion zstyles ──
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*:git-checkout:*' sort false
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' menu no
if (( $+commands[eza] )); then
    zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza --color=always $realpath'
    zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'eza --color=always $realpath'
fi

# ── Zoxide ──
if (( $+commands[zoxide] )); then
    _zsh_cache_eval zoxide 'zoxide init --cmd cd zsh'
fi

# ── FZF + fd ──
if (( $+commands[fzf] && $+commands[fd] )); then
    [ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
    export FZF_DEFAULT_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND="fd --type=d --hidden --strip-cwd-prefix --exclude .git"

    _fzf_compgen_path() {
      fd --hidden --exclude .git . "$1"
    }

    _fzf_compgen_dir() {
      fd --type=d --hidden --exclude .git . "$1"
    }
fi

# ── Bat ──
if (( $+commands[bat] )); then
    export BAT_THEME=tokyonight_night
    alias cat=bat
    # Prettier man pages via bat. `col -bx` strips backspace/overstrike so bat's
    # `man` syntax highlighting renders cleanly; MANROFFOPT=-c keeps groff colors.
    export MANPAGER="sh -c 'col -bx | bat -l man -p'"
    export MANROFFOPT="-c"
    # Colorized --help output: `bathelp foo` == `foo --help` piped through bat.
    alias bathelp='bat --plain --language=help'
    help() { "$@" --help 2>&1 | bat --plain --language=help; }
fi

# ── FZF + Eza + Bat integration ──
if (( $+commands[fzf] && $+commands[eza] && $+commands[bat] )); then
    export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always --line-range :500 {}'"
    export FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} | head -200'"

    _fzf_comprun() {
      local command=$1
      shift

      case "$command" in
        cd)           fzf --preview 'eza --tree --color=always {} | head -200' "$@" ;;
        export|unset) fzf --preview "eval 'echo $'{}"         "$@" ;;
        ssh)          fzf --preview 'dig {}'                   "$@" ;;
        *)            fzf --preview "bat -n --color=always --line-range :500 {}" "$@" ;;
      esac
    }
fi

# ── Neovim ──
if (( $+commands[nvim] )); then
    alias vim="nvim"
    alias v="nvim"
    export EDITOR=nvim
    export SUDO_EDITOR=$(which nvim)
    # Python PATH fix for Neovim providers
    _python3_path=$(realpath ${commands[python3]} 2>/dev/null) && export PATH="${_python3_path:h}:$PATH"
    unset _python3_path
fi

# ── UV completions ──
(( $+commands[uv] ))  && _zsh_lazy_completion uv  'uv generate-shell-completion zsh'
(( $+commands[uvx] )) && _zsh_lazy_completion uvx 'uvx --generate-shell-completion zsh'

# ── Yazi ──
if (( $+commands[yazi] )); then
    function y() {
        local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
        yazi "$@" --cwd-file="$tmp"
        if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
            builtin cd -- "$cwd"
        fi
        rm -f -- "$tmp"
    }
fi

# ── GitHub token (lazy-loaded at first prompt) ──
if (( $+commands[gh] )); then
    _gh_token_precmd() {
        if gh auth status &>/dev/null; then
            export GITHUB_TOKEN="$(gh auth token 2>/dev/null)"
        fi
        add-zsh-hook -d precmd _gh_token_precmd
    }
    add-zsh-hook precmd _gh_token_precmd
fi

# ── conda (lazy Miniforge hook) ───────────────────────────────────────────────
# Miniforge is NOT installed by this repo — hand-installed where needed. The
# guard keeps machines without it clean. Unrelated to mise's conda: backend.
if [[ -x "$HOME/miniforge3/bin/conda" ]]; then
    _conda_init() {
        unfunction conda mamba 2>/dev/null
        local __conda_setup="$("$HOME/miniforge3/bin/conda" 'shell.zsh' 'hook' 2>/dev/null)"
        if [ $? -eq 0 ]; then eval "$__conda_setup"
        elif [ -f "$HOME/miniforge3/etc/profile.d/conda.sh" ]; then . "$HOME/miniforge3/etc/profile.d/conda.sh"
        else export PATH="$HOME/miniforge3/bin:$PATH"
        fi
        [[ -f "$HOME/miniforge3/etc/profile.d/mamba.sh" ]] && . "$HOME/miniforge3/etc/profile.d/mamba.sh"
    }
    conda() { _conda_init; conda "$@" }
    mamba() { _conda_init; mamba "$@" }
fi

# ── Misc guarded completions ──
(( $+commands[op] ))  && _zsh_lazy_completion op 'op completion zsh'
(( $+commands[fga] )) && _zsh_lazy_completion fga 'fga completion zsh'
if (( $+commands[register-python-argcomplete] )); then _zsh_cache_eval argcomplete-cz 'register-python-argcomplete cz'; fi
if (( $+commands[kubectl] )); then
    alias k=kubectl
    kubectl() { unfunction kubectl; source <(command kubectl completion zsh); command kubectl "$@" }
fi

# ── Prompt (Powerlevel10k) ────────────────────────────────────────────────────
# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh — then recapture
# with: mise dotfiles add ~/.p10k.zsh
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
# Per-machine p10k tweaks (e.g. OS icon override). Sourced after .p10k.zsh so
# it survives `p10k configure` regenerations.
[[ -f ~/.p10k.local.zsh ]] && source ~/.p10k.local.zsh

# ── Machine-local overlay ─────────────────────────────────────────────────────
# Anything specific to this machine (extra PATH entries, vagrant/java/go-by-hand
# stanzas, work tooling) belongs in ~/.zshrc.local, which is never committed.
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
