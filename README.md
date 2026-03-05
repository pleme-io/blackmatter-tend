# blackmatter-tend

Home-manager module that runs the [tend](https://github.com/pleme-io/tend) workspace repository manager as a persistent daemon service. Keeps workspace repos synced and fetched on a configurable interval via launchd (macOS) or systemd (Linux), with built-in log rotation on both platforms.

## Architecture

```
blackmatter-tend
  module/
    default.nix     # HM module (launchd + systemd + log rotation)
```

The module uses substrate's `hm-service-helpers.nix` factory pattern to generate platform-specific service definitions from a single configuration. On Darwin it creates a launchd agent plus a newsyslog-based log rotation agent; on Linux it creates a systemd user service plus a logrotate timer.

### Data flow

```
services.tend.daemon options
  |
  v
daemonArgs = ["daemon" "--interval" N "--fetch" "--quiet" ...]
  |
  +--- Darwin ---> launchd.agents.tend-daemon (io.pleme.tend-daemon)
  |                launchd.agents.tend-log-rotate (newsyslog, hourly)
  |
  +--- Linux ----> systemd.user.services.tend-daemon
                   systemd.user.services.tend-log-rotate (logrotate timer)
```

## Features

- **Cross-platform daemon** -- runs `tend daemon` as a launchd agent (macOS) or systemd user service (Linux) with automatic restart
- **Configurable sync interval** -- default 5 minutes, adjustable per-user
- **Workspace filtering** -- limit to a specific workspace or sync all
- **Git fetch** -- optionally fetches all existing repos each cycle
- **GitHub token forwarding** -- `githubTokenFile` option for environments where env vars are not inherited (launchd, systemd)
- **Log rotation** -- platform-native rotation: newsyslog on Darwin (hourly check), logrotate on Linux (timer-based)
- **Configurable log retention** -- max size, file count, and compression options

## Installation

Add as a flake input:

```nix
{
  inputs = {
    blackmatter-tend = {
      url = "github:pleme-io/blackmatter-tend";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.substrate.follows = "substrate";
    };
  };
}
```

Import in your home-manager configuration:

```nix
{ inputs, ... }: {
  imports = [ inputs.blackmatter-tend.homeManagerModules.default ];
}
```

## Usage

### Basic daemon (all workspaces, 5-minute interval)

```nix
{
  services.tend.daemon = {
    enable = true;
    package = pkgs.tend;  # or your custom tend package
  };
}
```

### Custom interval with workspace filter

```nix
{
  services.tend.daemon = {
    enable = true;
    package = pkgs.tend;
    interval = 600;                  # 10 minutes
    workspace = "pleme-io";          # only sync this workspace
    fetch = true;                    # git fetch existing repos
    quiet = true;                    # suppress per-repo output
  };
}
```

### With GitHub token for private repos

```nix
{
  services.tend.daemon = {
    enable = true;
    package = pkgs.tend;
    githubTokenFile = config.sops.secrets.github-token.path;
  };
}
```

### Custom log rotation

```nix
{
  services.tend.daemon = {
    enable = true;
    package = pkgs.tend;
    logRotation = {
      maxSize = "50M";      # rotate at 50 MB
      keep = 5;             # keep 5 rotated files
      compress = true;      # gzip rotated files
    };
  };
}
```

## Configuration Reference

### Daemon options (`services.tend.daemon.*`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | `bool` | `false` | Enable tend daemon service |
| `package` | `package` | `pkgs.tend` | Tend package providing the binary |
| `interval` | `int` | `300` | Sync interval in seconds |
| `workspace` | `nullOr str` | `null` | Limit to a specific workspace (null = all) |
| `fetch` | `bool` | `true` | Git fetch existing repos each cycle |
| `quiet` | `bool` | `true` | Suppress per-repo output |
| `githubTokenFile` | `nullOr str` | `null` | Path to file containing GitHub token |

### Log rotation options (`services.tend.daemon.logRotation.*`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `maxSize` | `str` | `"10M"` | Max log file size before rotation |
| `keep` | `int` | `3` | Number of rotated files to keep |
| `compress` | `bool` | `true` | Compress rotated log files |

## Platform Behavior

### macOS (Darwin)

- **Service:** `launchd.agents.tend-daemon` with label `io.pleme.tend-daemon`
- **Logs:** `~/Library/Logs/tend-daemon.log` and `tend-daemon.err`
- **Rotation:** newsyslog config at `~/.local/share/tend/newsyslog.d/tend-daemon.conf`, checked hourly by a companion launchd agent (`io.pleme.tend-log-rotate`)

### Linux

- **Service:** `systemd.user.services.tend-daemon`
- **Logs:** `~/.local/share/tend/logs/tend-daemon.log` and `tend-daemon.err`
- **Rotation:** logrotate config at `~/.config/logrotate.d/tend-daemon`, triggered by a systemd user timer (`tend-log-rotate.timer`, runs every hour)

## Development

```bash
# Check the flake
nix flake check

# Evaluate the module
nix eval .#homeManagerModules.default --apply '(m: builtins.typeOf m)'
```

The module depends on substrate's `hm-service-helpers.nix` for the `mkLaunchdService` and `mkSystemdService` helpers. These are injected via the module factory pattern in `flake.nix`:

```nix
homeManagerModules.default = import ./module {
  hmHelpers = import "${substrate}/lib/hm-service-helpers.nix" { lib = nixpkgs.lib; };
};
```

## Project Structure

```
flake.nix               # Flake: imports substrate, exports homeManagerModules.default
module/
  default.nix           # HM module: options, launchd agent, systemd service, log rotation
```

## Related Projects

- [tend](https://github.com/pleme-io/tend) -- The workspace repository manager binary this module runs
- [substrate](https://github.com/pleme-io/substrate) -- Provides `hm-service-helpers.nix` (mkLaunchdService, mkSystemdService)
- [blackmatter](https://github.com/pleme-io/blackmatter) -- Module aggregator that consumes this repo
- [blackmatter-pleme](https://github.com/pleme-io/blackmatter-pleme) -- Org conventions and tend workspace configuration

## License

MIT
