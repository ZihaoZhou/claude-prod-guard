# Claude Production Guard

A Claude Code hook that prevents accidental modification of production services.

## Features

- **Docker Protection**: Blocks `docker stop/restart/rm/kill` on production containers
- **File Protection**: Blocks writes to production directories
- **Port Protection**: Blocks binding to production ports
- **Smart pkill Detection**: Blocks `pkill/killall` that could affect production
- **Dev Override**: Containers with `-dev` suffix are always allowed
- **Easy Override**: Bypass protection with `CLAUDE_PROD_OVERRIDE=true`

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/claude-prod-guard.git
cd claude-prod-guard
./install.sh
```

## Configuration

Edit `~/.claude/hooks/production.yaml`:

```yaml
# Production ports (block port binding)
ports:
  - 80
  - 443
  - 3000

# Production containers (block mutations)
containers:
  - my-app
  - my-db

# Production directories (block file writes)
directories:
  - $HOME/production
  - /etc/nginx

# Safe directories (always allowed)
safe_directories:
  - $HOME/dev

# Keywords for pkill detection
process_keywords:
  - myapp
  - nginx
```

## Usage

Once installed, the hook runs automatically. When blocked:

```
BLOCKED: Docker mutation on production container: my-app
Suggestion: Use docker logs/inspect for read-only operations
Override: CLAUDE_PROD_OVERRIDE=true <command>
```

To bypass (after confirming with user):

```bash
CLAUDE_PROD_OVERRIDE=true docker restart my-app
```

## How It Works

The hook intercepts Claude Code's `Bash`, `Write`, and `Edit` tool calls:

1. Parses the command/file path
2. Checks against production resources in `production.yaml`
3. Allows read-only operations (docker logs, inspect, etc.)
4. Blocks mutations on production resources
5. Always allows `-dev` suffixed containers

## Dependencies

- `jq` - JSON parsing
- `yq` - YAML parsing (pip install yq)

## License

MIT
