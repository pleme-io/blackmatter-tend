# Tend home-manager module — persistent background services
#
# Namespaces:
#   services.tend.daemon.*       — sync + fetch repos on interval
#   services.tend.flakeUpdate.*  — idempotent flake.lock propagation loop
#
# Both are opt-in, independent services running under launchd (Darwin) or
# systemd (Linux). They can run side-by-side; they write to separate logs
# and have separate rotation policies.
#
# Module factory: receives { hmHelpers } from flake.nix, returns HM module.
{ hmHelpers }:
{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  inherit (hmHelpers) mkLaunchdService mkSystemdService;
  cfg = config.services.tend.daemon;
  fcfg = config.services.tend.flakeUpdate;
  isDarwin = pkgs.stdenv.isDarwin;

  logDir =
    if isDarwin
    then "${config.home.homeDirectory}/Library/Logs"
    else "${config.home.homeDirectory}/.local/share/tend/logs";

  # Build the full argument list for `tend daemon`
  daemonArgs =
    ["daemon" "--interval" (toString cfg.interval)]
    ++ optionals cfg.quiet ["--quiet"]
    ++ optionals (cfg.workspace != null) ["--workspace" cfg.workspace]
    ++ optionals cfg.fetch ["--fetch"]
    ++ optionals (cfg.githubTokenFile != null) ["--github-token-file" cfg.githubTokenFile];

  flakeUpdateArgs =
    ["flake-update-daemon"
     "--min-interval" (toString fcfg.minInterval)
     "--max-interval" (toString fcfg.maxInterval)]
    ++ optionals fcfg.quiet ["--quiet"]
    ++ optionals (fcfg.workspace != null) ["--workspace" fcfg.workspace]
    ++ optionals (fcfg.githubTokenFile != null) ["--github-token-file" fcfg.githubTokenFile];

  # Paths to `nix` and `git` binaries that the flake-update daemon shells out
  # to. launchd and systemd don't inherit the user's interactive shell PATH,
  # so we give them an explicit one that covers:
  #   - /run/current-system/sw/bin       (nix-darwin system profile — nix)
  #   - /etc/profiles/per-user/$USER/bin (home-manager profile — git)
  #   - /nix/var/nix/profiles/default/bin (global default profile)
  #   - /usr/bin, /bin                    (stock OS utilities — /bin/sh etc.)
  flakeUpdatePath =
    if isDarwin
    then "/run/current-system/sw/bin:/etc/profiles/per-user/${config.home.username}/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    else "/run/current-system/sw/bin:/etc/profiles/per-user/${config.home.username}/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin";

  flakeUpdateEnv =
    {
      PATH = flakeUpdatePath;
      HOME = config.home.homeDirectory;
    }
    // fcfg.extraEnv;

  daemonEnv = {} // cfg.extraEnv;
in {
  options.services.tend.daemon = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable tend daemon service (sync + fetch repos on interval)";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.tend;
      description = "Tend package providing the tend binary";
    };

    interval = mkOption {
      type = types.int;
      default = 300;
      description = "Sync interval in seconds (default 5 minutes)";
    };

    workspace = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Limit to a specific workspace by name (null = all workspaces)";
    };

    fetch = mkOption {
      type = types.bool;
      default = true;
      description = "Git fetch existing repos each cycle";
    };

    quiet = mkOption {
      type = types.bool;
      default = true;
      description = "Suppress per-repo output (recommended for daemon mode)";
    };

    githubTokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to file containing GitHub token (for launchd/systemd environments where env vars aren't inherited)";
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = ''
        Extra environment variables to set on the daemon's launchd/systemd
        service. Useful for opt-in feature flags (e.g.
        `TEND_PRUNE_DIRENV = "1"`) without rebuilding the upstream tend
        binary or extending this module's option set.
      '';
    };

    logRotation = {
      maxSize = mkOption {
        type = types.str;
        default = "10M";
        description = "Maximum log file size before rotation (newsyslog format on Darwin, logrotate on Linux)";
      };

      keep = mkOption {
        type = types.int;
        default = 3;
        description = "Number of rotated log files to keep";
      };

      compress = mkOption {
        type = types.bool;
        default = true;
        description = "Compress rotated log files";
      };
    };
  };

  options.services.tend.flakeUpdate = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the tend flake-update daemon — runs `tend flake-update-daemon`
        as a launchd (Darwin) or systemd (Linux) service. The daemon
        continuously propagates flake.lock updates across every workspace with
        `flake_deps` configured, using an upstream-HEAD pre-flight check so
        converged cycles do no work. Sleep interval grows exponentially up to
        `maxInterval` when converged and resets on any work.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.tend;
      description = "Tend package providing the tend binary";
    };

    minInterval = mkOption {
      type = types.int;
      default = 60;
      description = "Minimum sleep between cycles (seconds). Used after any work is done.";
    };

    maxInterval = mkOption {
      type = types.int;
      default = 3600;
      description = "Maximum sleep between cycles when converged (seconds).";
    };

    workspace = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Limit to a specific workspace by name (null = every workspace with flake_deps)";
    };

    quiet = mkOption {
      type = types.bool;
      default = true;
      description = "Suppress per-step output (recommended for daemon mode)";
    };

    githubTokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to file containing GitHub token (for launchd/systemd environments where env vars aren't inherited)";
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = ''
        Extra environment variables to set on the flake-update daemon's
        launchd/systemd service, merged on top of the defaults (PATH,
        HOME). Used for opt-in feature flags consumed by the tend binary,
        notably `TEND_PRUNE_DIRENV = "1"` to fire `seibi direnv-prune`
        after each successful flake.lock bump.
      '';
    };

    logRotation = {
      maxSize = mkOption {
        type = types.str;
        default = "10M";
        description = "Maximum log file size before rotation";
      };

      keep = mkOption {
        type = types.int;
        default = 3;
        description = "Number of rotated log files to keep";
      };

      compress = mkOption {
        type = types.bool;
        default = true;
        description = "Compress rotated log files";
      };
    };
  };

  config = mkMerge [
    # Darwin: launchd agent + newsyslog log rotation
    (mkIf (cfg.enable && isDarwin) (mkMerge [
      # Ensure log directory exists
      {
        home.activation.tend-log-dir = lib.hm.dag.entryAfter ["writeBoundary"] ''
          run mkdir -p "${logDir}"
        '';
      }

      (mkLaunchdService {
        name = "tend-daemon";
        label = "io.pleme.tend-daemon";
        command = "${cfg.package}/bin/tend";
        args = daemonArgs;
        env = daemonEnv;
        logDir = logDir;
      })

      # newsyslog-based log rotation for Darwin
      # newsyslog.d config: rotates when file exceeds maxSize, keeps N archives
      {
        home.file.".local/share/tend/newsyslog.d/tend-daemon.conf".text = let
          logFile = "${logDir}/tend-daemon.log";
          errFile = "${logDir}/tend-daemon.err";
          count = toString cfg.logRotation.keep;
          size = let
            # Convert human-readable size to KB for newsyslog
            raw = cfg.logRotation.maxSize;
            unit = builtins.substring ((builtins.stringLength raw) - 1) 1 raw;
            num = builtins.substring 0 ((builtins.stringLength raw) - 1) raw;
            sizeKB =
              if unit == "M" || unit == "m"
              then toString ((lib.toInt num) * 1024)
              else if unit == "G" || unit == "g"
              then toString ((lib.toInt num) * 1024 * 1024)
              else if unit == "K" || unit == "k"
              then num
              else raw;
          in
            sizeKB;
          flags =
            if cfg.logRotation.compress
            then "GN"
            else "N";
        in ''
          # logfilename          [owner:group]  mode  count  size  when  flags
          ${logFile}                             644   ${count}    ${size}  *     ${flags}
          ${errFile}                             644   ${count}    ${size}  *     ${flags}
        '';

        # Periodic newsyslog invocation via launchd
        launchd.agents.tend-log-rotate = {
          enable = true;
          config = {
            Label = "io.pleme.tend-log-rotate";
            ProgramArguments = [
              "/usr/sbin/newsyslog"
              "-f"
              "${config.home.homeDirectory}/.local/share/tend/newsyslog.d/tend-daemon.conf"
            ];
            StartInterval = 3600; # check every hour
            ProcessType = "Background";
            LowPriorityIO = true;
            Nice = 10;
            StandardOutPath = "/dev/null";
            StandardErrorPath = "/dev/null";
          };
        };
      }
    ]))

    # Darwin: flake-update daemon + log rotation
    (mkIf (fcfg.enable && isDarwin) (mkMerge [
      {
        home.activation.tend-flake-update-log-dir = lib.hm.dag.entryAfter ["writeBoundary"] ''
          run mkdir -p "${logDir}"
        '';
      }

      (mkLaunchdService {
        name = "tend-flake-update";
        label = "io.pleme.tend-flake-update";
        command = "${fcfg.package}/bin/tend";
        args = flakeUpdateArgs;
        env = flakeUpdateEnv;
        logDir = logDir;
      })

      {
        home.file.".local/share/tend/newsyslog.d/tend-flake-update.conf".text = let
          logFile = "${logDir}/tend-flake-update.log";
          errFile = "${logDir}/tend-flake-update.err";
          count = toString fcfg.logRotation.keep;
          size = let
            raw = fcfg.logRotation.maxSize;
            unit = builtins.substring ((builtins.stringLength raw) - 1) 1 raw;
            num = builtins.substring 0 ((builtins.stringLength raw) - 1) raw;
            sizeKB =
              if unit == "M" || unit == "m"
              then toString ((lib.toInt num) * 1024)
              else if unit == "G" || unit == "g"
              then toString ((lib.toInt num) * 1024 * 1024)
              else if unit == "K" || unit == "k"
              then num
              else raw;
          in
            sizeKB;
          flags =
            if fcfg.logRotation.compress
            then "GN"
            else "N";
        in ''
          # logfilename          [owner:group]  mode  count  size  when  flags
          ${logFile}                             644   ${count}    ${size}  *     ${flags}
          ${errFile}                             644   ${count}    ${size}  *     ${flags}
        '';
      }
    ]))

    # Linux: flake-update daemon + logrotate config
    (mkIf (fcfg.enable && !isDarwin) (mkMerge [
      {
        home.activation.tend-flake-update-log-dir = lib.hm.dag.entryAfter ["writeBoundary"] ''
          run mkdir -p "${logDir}"
        '';
      }

      (mkSystemdService {
        name = "tend-flake-update";
        description = "Tend flake-update daemon — propagate flake.lock updates";
        command = "${fcfg.package}/bin/tend";
        args = flakeUpdateArgs;
        env = flakeUpdateEnv;
      })

      {
        home.file.".config/logrotate.d/tend-flake-update".text = ''
          ${logDir}/tend-flake-update.log ${logDir}/tend-flake-update.err {
              size ${fcfg.logRotation.maxSize}
              rotate ${toString fcfg.logRotation.keep}
              ${optionalString fcfg.logRotation.compress "compress"}
              missingok
              notifempty
              copytruncate
          }
        '';
      }
    ]))

    # Linux: systemd service + logrotate config
    (mkIf (cfg.enable && !isDarwin) (mkMerge [
      # Ensure log directory exists
      {
        home.activation.tend-log-dir = lib.hm.dag.entryAfter ["writeBoundary"] ''
          run mkdir -p "${logDir}"
        '';
      }

      (mkSystemdService {
        name = "tend-daemon";
        description = "Tend workspace daemon — sync + fetch repos";
        command = "${cfg.package}/bin/tend";
        args = daemonArgs;
        env = daemonEnv;
      })

      # logrotate config for Linux
      {
        home.file.".config/logrotate.d/tend-daemon".text = ''
          ${logDir}/tend-daemon.log ${logDir}/tend-daemon.err {
              size ${cfg.logRotation.maxSize}
              rotate ${toString cfg.logRotation.keep}
              ${optionalString cfg.logRotation.compress "compress"}
              missingok
              notifempty
              copytruncate
          }
        '';

        # Periodic logrotate via systemd timer
        systemd.user.services.tend-log-rotate = {
          Unit.Description = "Rotate tend daemon logs";
          Service = {
            Type = "oneshot";
            ExecStart = "${pkgs.logrotate}/bin/logrotate ${config.home.homeDirectory}/.config/logrotate.d/tend-daemon --state ${config.home.homeDirectory}/.local/share/tend/logrotate.state";
          };
        };

        systemd.user.timers.tend-log-rotate = {
          Unit.Description = "Rotate tend daemon logs (timer)";
          Timer = {
            OnBootSec = "5min";
            OnUnitActiveSec = "1h";
            Unit = "tend-log-rotate.service";
          };
          Install.WantedBy = ["timers.target"];
        };
      }
    ]))
  ];
}
