#!/bin/bash
# Claude Production Guard - Installation Script

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "=== Claude Production Guard Installer ==="
echo ""

# Check dependencies
check_deps() {
    local missing=()

    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    if ! command -v yq &> /dev/null; then
        missing+=("yq")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        echo "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  Ubuntu/Debian: sudo apt-get install jq && pip install yq"
        echo "  macOS: brew install jq yq"
        echo ""
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Create hooks directory
setup_hooks_dir() {
    if [ ! -d "$HOOKS_DIR" ]; then
        echo "Creating $HOOKS_DIR..."
        mkdir -p "$HOOKS_DIR"
    fi
}

# Copy main script
install_script() {
    echo "Installing production-guard.sh..."
    cp "$SCRIPT_DIR/production-guard.sh" "$HOOKS_DIR/"
    chmod +x "$HOOKS_DIR/production-guard.sh"
}

# Setup config file
setup_config() {
    if [ -f "$HOOKS_DIR/production.yaml" ]; then
        echo "Config file already exists: $HOOKS_DIR/production.yaml"
        read -p "Overwrite with example? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
    fi

    echo "Creating config template..."
    cp "$SCRIPT_DIR/production.yaml.example" "$HOOKS_DIR/production.yaml"
    echo ""
    echo "IMPORTANT: Edit $HOOKS_DIR/production.yaml"
    echo "           Configure your production resources!"
}

# Update settings.json
update_settings() {
    echo "Updating Claude settings..."

    mkdir -p "$(dirname "$SETTINGS_FILE")"

    # Create new settings if doesn't exist
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo '{}' > "$SETTINGS_FILE"
    fi

    # Check if hooks already configured
    if jq -e '.hooks.PreToolUse' "$SETTINGS_FILE" > /dev/null 2>&1; then
        # Check if our hook is already there
        if jq -e '.hooks.PreToolUse[] | select(.hooks[].command | contains("production-guard.sh"))' "$SETTINGS_FILE" > /dev/null 2>&1; then
            echo "Hook already configured in settings.json"
            return
        fi

        echo "Adding hook to existing PreToolUse hooks..."
        local new_hook='{"matcher":"Bash|Write|Edit","hooks":[{"type":"command","command":"~/.claude/hooks/production-guard.sh"}]}'
        jq ".hooks.PreToolUse += [$new_hook]" "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp"
        mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    else
        echo "Creating hooks configuration..."
        jq '. + {
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Bash|Write|Edit",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "~/.claude/hooks/production-guard.sh"
                            }
                        ]
                    }
                ]
            }
        }' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp"
        mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    fi
}

# Main
main() {
    check_deps
    setup_hooks_dir
    install_script
    setup_config
    update_settings

    echo ""
    echo "=== Installation Complete ==="
    echo ""
    echo "Next steps:"
    echo "1. Edit ~/.claude/hooks/production.yaml"
    echo "   Configure your production containers, ports, and directories"
    echo ""
    echo "2. Restart Claude Code for hooks to take effect"
    echo ""
    echo "Override protection when needed:"
    echo "   CLAUDE_PROD_OVERRIDE=true <command>"
    echo ""
}

main "$@"
