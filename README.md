# blackmatter-tend

Home-manager module for the Tend workspace daemon service.

## Overview

Runs `tend daemon` as a persistent launchd (Darwin) or systemd (Linux) service to keep workspace repos synced and fetched on an interval. Includes log rotation via newsyslog (Darwin) or logrotate (Linux). Uses substrate's `hm-service-helpers` for cross-platform service patterns.

## Flake Outputs

- `homeManagerModules.default` -- home-manager module at `services.tend.daemon`

## Usage

```nix
{
  inputs.blackmatter-tend.url = "github:pleme-io/blackmatter-tend";
}
```

```nix
services.tend.daemon = {
  enable = true;
  interval = 300;       # sync every 5 minutes
  fetch = true;         # git fetch existing repos
  quiet = true;         # suppress per-repo output
  workspace = null;     # null = all workspaces
  githubTokenFile = "/run/secrets/github-token";
};
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `interval` | int | 300 | Sync interval in seconds |
| `fetch` | bool | true | Git fetch existing repos each cycle |
| `quiet` | bool | true | Suppress per-repo output |
| `workspace` | string? | null | Limit to specific workspace |
| `githubTokenFile` | string? | null | Path to GitHub token file |
| `logRotation.maxSize` | string | "10M" | Max log size before rotation |
| `logRotation.keep` | int | 3 | Rotated files to keep |

## Structure

- `module/` -- home-manager module factory (receives `hmHelpers` from flake.nix)
