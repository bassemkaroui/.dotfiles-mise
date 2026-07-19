# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# If not running interactively, don't do anything
case $- in
*i*) ;;
*) return ;;
esac

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# make less more friendly for non-text input files, see lesspipe(1)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
xterm-color | *-256color) color_prompt=yes ;;
esac

########################### Git ################################
# Legacy per-machine completion/prompt helpers — only sourced when present.
[ -f ~/.git-completion.bash ] && source ~/.git-completion.bash
if [ -f ~/.git-prompt.sh ]; then
    source ~/.git-prompt.sh
    export GIT_PS1_SHOWDIRTYSTATE=1
fi
# Fallback so the prompts below never break when __git_ps1 is absent.
command -v __git_ps1 >/dev/null 2>&1 || __git_ps1() { :; }
################################################################
if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
        # We have color support; assume it's compliant with Ecma-48
        # (ISO/IEC-6429). (Lack of such support is extremely rare, and such
        # a case would tend to support setf rather than setaf.)
        color_prompt=yes
    else
        color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]$(__git_ps1 " (%s)")\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w$(__git_ps1 " (%s)")\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm* | rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*) ;;
esac

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# some more ls aliases
alias ll='ls -lh'
alias la='ls -A'
alias l='ls -CF'

# Add an "alert" alias for long running commands.  Use like so:
#   sleep 10; alert
alert() {
    notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" \
        "$(history | tail -n1 | sed -e 's/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//')"
}

# Alias definitions.
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

# >>> conda initialize (lazy) >>>
# Mirrors the zsh hook. Miniforge is NOT installed by this repo, so the block is
# guarded: on a machine without it, nothing is defined and `conda` stays unset
# rather than resolving to a bogus PATH entry. Install Miniforge by hand if a
# machine needs interactive conda envs.
if [ -x "$HOME/miniforge3/bin/conda" ]; then
    _conda_init() {
        unset -f conda mamba 2>/dev/null
        local __conda_setup
        if __conda_setup="$("$HOME/miniforge3/bin/conda" 'shell.bash' 'hook' 2>/dev/null)"; then
            eval "$__conda_setup"
        elif [ -f "$HOME/miniforge3/etc/profile.d/conda.sh" ]; then
            . "$HOME/miniforge3/etc/profile.d/conda.sh"
        else
            export PATH="$HOME/miniforge3/bin:$PATH"
        fi
        [ -f "$HOME/miniforge3/etc/profile.d/mamba.sh" ] && . "$HOME/miniforge3/etc/profile.d/mamba.sh"
    }
    conda() { _conda_init; conda "$@"; }
    mamba() { _conda_init; mamba "$@"; }
fi
# <<< conda initialize <<<

[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

export MISE_TRUSTED_CONFIG_PATHS="$HOME/.config/mise"
if [ -x "$HOME/.local/bin/mise" ]; then
    eval "$("$HOME/.local/bin/mise" activate bash)"
elif command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi

# GitHub token for API access (e.g., remote-nvim downloads)
if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    export GITHUB_TOKEN="$(gh auth token 2>/dev/null)"
fi

# Machine-local overlay (never committed)
[ -f ~/.bashrc.local ] && . ~/.bashrc.local
