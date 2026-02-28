# Tend daemon home-manager module — persistent sync + fetch service
#
# Namespace: services.tend.daemon.*
#
# Runs `tend daemon` as a launchd (Darwin) or systemd (Linux) service
# to keep workspace repos synced and fetched on an interval.
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
