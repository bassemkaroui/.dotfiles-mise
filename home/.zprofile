# Ensure ~/.local/bin is in PATH (for tools installed outside package managers)
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
