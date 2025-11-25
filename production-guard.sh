#!/bin/bash
# Production Guard Hook for Claude Code
# Prevents accidental modification of production services

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/production.yaml"

# Check for override
if [[ "${CLAUDE_PROD_OVERRIDE:-}" == "true" ]]; then
    exit 0
fi

# Read JSON from stdin
INPUT=$(cat)

# Extract tool name and input
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // empty')

# Load config using yq
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Warning: Config file not found: $CONFIG_FILE" >&2
        return 1
    fi
}

get_ports() {
    yq -r '.ports[]' "$CONFIG_FILE" 2>/dev/null | tr '\n' ' '
}

get_containers() {
    yq -r '.containers[]' "$CONFIG_FILE" 2>/dev/null
}

get_prod_dirs() {
    yq -r '.directories[]' "$CONFIG_FILE" 2>/dev/null | sed "s|\$HOME|$HOME|g; s|~|$HOME|g"
}

get_safe_dirs() {
    yq -r '.safe_directories[]' "$CONFIG_FILE" 2>/dev/null | sed "s|\$HOME|$HOME|g; s|~|$HOME|g"
}

get_process_keywords() {
    yq -r '.process_keywords[]' "$CONFIG_FILE" 2>/dev/null | tr '\n' '|' | sed 's/|$//'
}

# Check if a path is in production directories
is_prod_path() {
    local path="$1"
    # Resolve to absolute path if relative
    if [[ ! "$path" = /* ]]; then
        path="$(pwd)/$path"
    fi
    # Normalize path
    path=$(realpath -m "$path" 2>/dev/null || echo "$path")

    while IFS= read -r prod_dir; do
        if [[ "$path" == "$prod_dir"* ]]; then
            # Check if it's in a safe directory (safe takes precedence)
            while IFS= read -r safe_dir; do
                if [[ "$path" == "$safe_dir"* ]]; then
                    return 1  # Safe
                fi
            done < <(get_safe_dirs)
            return 0  # Production
        fi
    done < <(get_prod_dirs)
    return 1  # Not production
}

# Check if container is production
is_prod_container() {
    local container="$1"
    while IFS= read -r prod_container; do
        if [[ "$container" == "$prod_container" ]]; then
            return 0
        fi
    done < <(get_containers)
    return 1
}

# Check if port is production
is_prod_port() {
    local port="$1"
    local ports=$(get_ports)
    for p in $ports; do
        if [[ "$port" == "$p" ]]; then
            return 0
        fi
    done
    return 1
}

# Block with message
block() {
    local reason="$1"
    local suggestion="${2:-}"
    echo "BLOCKED: $reason" >&2
    if [[ -n "$suggestion" ]]; then
        echo "Suggestion: $suggestion" >&2
    fi
    echo "Override: CLAUDE_PROD_OVERRIDE=true <command>" >&2
    exit 2
}

# Handle Write/Edit tools
handle_file_tool() {
    local file_path=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')

    if [[ -z "$file_path" ]]; then
        exit 0  # No file path, allow
    fi

    if is_prod_path "$file_path"; then
        block "Writing to production directory: $file_path" "Work in safe directories (check production.yaml)"
    fi

    exit 0
}

# Handle Bash tool
handle_bash() {
    local cmd=$(echo "$TOOL_INPUT" | jq -r '.command // empty')

    if [[ -z "$cmd" ]]; then
        exit 0
    fi

    # Always blocked commands (dangerous globally)
    if echo "$cmd" | grep -qE '(systemctl\s+(stop|restart|disable)|nginx\s+-s\s+(stop|quit|reload))'; then
        block "System service modification command detected" "These commands affect all services. Manual intervention required."
    fi

    # Check for docker commands
    if echo "$cmd" | grep -qE '^docker\s|;\s*docker\s|&&\s*docker\s|\|\s*docker\s'; then
        # Extract docker subcommand
        local docker_action=$(echo "$cmd" | grep -oE 'docker\s+(stop|restart|rm|kill|pause|unpause|compose\s+(down|stop|restart|rm))' | head -1)

        if [[ -n "$docker_action" ]]; then
            # Check each production container
            while IFS= read -r container; do
                if echo "$cmd" | grep -qE "(docker\s+\S+\s+.*\b${container}\b|docker\s+compose.*\b${container}\b)"; then
                    # Allow if it's a -dev variant
                    if echo "$cmd" | grep -qE "\b${container}-dev\b"; then
                        continue
                    fi
                    block "Docker mutation on production container: $container" "Use docker logs/inspect for read-only operations"
                fi
            done < <(get_containers)

            # Check for docker compose in production directories
            while IFS= read -r prod_dir; do
                if echo "$cmd" | grep -qE "docker\s+compose.*-f\s+${prod_dir}|cd\s+${prod_dir}.*docker\s+compose"; then
                    block "Docker compose in production directory: $prod_dir" "Work in safe directories"
                fi
            done < <(get_prod_dirs)
        fi
    fi

    # Check for pkill/killall - smart detection
    if echo "$cmd" | grep -qE '\b(pkill|killall)\b'; then
        # Extract the pattern being killed
        local kill_pattern=$(echo "$cmd" | grep -oE '(pkill|killall)\s+(-\w+\s+)*[^|;&]+' | sed 's/^[^[:space:]]*\s*//')

        # Check if pattern could match production processes
        local prod_keywords=$(get_process_keywords)
        if [[ -n "$prod_keywords" ]] && echo "$kill_pattern" | grep -qiE "$prod_keywords"; then
            block "pkill/killall could affect production processes: $kill_pattern" "Be specific with container names or PIDs"
        fi

        # Block broad patterns
        if echo "$kill_pattern" | grep -qE '(-9\s+)?(-f\s+)?(node|python|java|docker)$'; then
            block "pkill/killall with broad pattern could affect production: $kill_pattern" "Use specific process names or PIDs"
        fi
    fi

    # Check for indirect kill patterns (lsof | xargs kill, fuser -k)
    if echo "$cmd" | grep -qE 'lsof.*\|\s*xargs.*kill|fuser\s+-k'; then
        # Check for production ports
        local ports=$(get_ports)
        for port in $ports; do
            if echo "$cmd" | grep -qE "[:=]${port}\b"; then
                block "Indirect kill on production port: $port" "Use docker commands for container management"
            fi
        done
    fi

    # Check for port binding on production ports
    if echo "$cmd" | grep -qE '(PORT|port)=|--port\s*[=\s]|-p\s+\d+:'; then
        local ports=$(get_ports)
        for port in $ports; do
            if echo "$cmd" | grep -qE "(PORT|port)[=\s]+${port}\b|--port[=\s]+${port}\b|-p\s+${port}:"; then
                block "Attempting to bind to production port: $port" "Use development ports (3081, 27018, 7701, etc.)"
            fi
        done
    fi

    # Check for file operations in production directories
    if echo "$cmd" | grep -qE '\b(rm|mv|cp|chmod|chown)\s+-'; then
        while IFS= read -r prod_dir; do
            if echo "$cmd" | grep -qE "\b(rm|mv|cp|chmod|chown)\s+.*${prod_dir}"; then
                block "File operation in production directory: $prod_dir" "Work in safe directories"
            fi
        done < <(get_prod_dirs)
    fi

    exit 0
}

# Main logic
load_config || exit 0  # If config fails, allow (fail open for usability)

case "$TOOL_NAME" in
    Write|Edit)
        handle_file_tool
        ;;
    Bash)
        handle_bash
        ;;
    *)
        exit 0  # Unknown tool, allow
        ;;
esac
