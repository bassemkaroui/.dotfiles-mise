#!/bin/bash

# Read stdin JSON input
input=$(cat)

# Extract values from JSON
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
model=$(echo "$input" | jq -r '.model.display_name')
output_style=$(echo "$input" | jq -r '.output_style.name // empty')
agent_name=$(echo "$input" | jq -r '.agent.name // empty')
used_percentage=$(echo "$input" | jq -r '.context_window.used_percentage // 0')

COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

COST_FMT=$(printf '$%.2f' "$COST")
DURATION_SEC=$((DURATION_MS / 1000))
HOURS=$((DURATION_SEC / 3600))
MINS=$(((DURATION_SEC % 3600) / 60))
# SECS=$((DURATION_SEC % 60))

# Current directory (abbreviated)
dir=$(basename "$cwd")

# Git status (if in a git repo)
git_info=""
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$cwd" -c core.fileMode=false -c advice.detachedHead=false symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" -c core.fileMode=false -c advice.detachedHead=false rev-parse --short HEAD 2>/dev/null)

    # Get git status
    git_status=$(git -C "$cwd" -c core.fileMode=false status --porcelain 2>/dev/null)

    if [ -z "$git_status" ]; then
        git_info="  $branch"
    else
        git_info="  $branch *"
    fi
fi

# Python environment
py_env=""
if [ -n "$CONDA_DEFAULT_ENV" ]; then
    py_env=" 🐍 $CONDA_DEFAULT_ENV"
elif [ -n "$VIRTUAL_ENV" ]; then
    venv_name=$(basename "$VIRTUAL_ENV")
    py_env=" 🐍 $venv_name"
fi

# Context window progress bar with color thresholds
progress_bar=""
context_color="\033[90m" # Default gray

if [ "$used_percentage" != "0" ] && [ "$used_percentage" != "null" ]; then
    bar_length=20
    filled=$(echo "scale=0; $used_percentage * $bar_length / 100" | bc -l 2>/dev/null || echo "0")
    empty=$((bar_length - filled))

    # Determine color based on usage percentage
    usage_int=$(printf "%.0f" "$used_percentage" 2>/dev/null || echo "0")
    if [ "$usage_int" -ge 70 ]; then
        context_color="\033[31m" # Red for 70%+
    elif [ "$usage_int" -ge 40 ]; then
        context_color="\033[33m" # Yellow for 40-69%
    fi

    # Create progress bar
    for ((i = 0; i < filled; i++)); do progress_bar+="█"; done
    for ((i = 0; i < empty; i++)); do progress_bar+="░"; done

    context_display=$(printf "%s %d%%" "$progress_bar" "$used_percentage")
else
    context_display="--"
fi

# User and hostname
user_host="$(whoami)@$(hostname -s)"

# LINE 1: Directory, Git, Python env
printf "%b" "\033[34m📁 $dir\033[0m"

if [ -n "$git_info" ]; then
    printf "%b" "\033[32m$git_info\033[0m"
fi

if [ -n "$py_env" ]; then
    printf "%b" "\033[35m$py_env\033[0m"
fi

printf "\n"

# LINE 2: Model, Agent (if present), Output Style (if not default), Cost, Time, Context
printf "%b" "\033[36m🤖 $model\033[0m"

if [ -n "$agent_name" ]; then
    printf "%b" "  \033[35m👤 Agent: $agent_name\033[0m"
fi

if [ -n "$output_style" ] && [ "$output_style" != "default" ]; then
    printf "%b" "  \033[33m[$output_style]\033[0m"
fi

printf "%b" "  \033[33m💰 ${COST_FMT}\033[0m"
printf "%b" "  \033[32m⏱ ${HOURS}h ${MINS}m\033[0m"
printf "%b" "  ${context_color}📊 Context: $context_display\033[0m"
