# Tend home-manager module — persistent background services
#
# Namespaces:
#   services.tend.daemon.*       — sync + pull repos on interval (reconciler)
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
  pcfg = config.services.tend.prebuild;
  isDarwin = pkgs.stdenv.isDarwin;

  logDir =
    if isDarwin
    then "${config.home.homeDirectory}/Library/Logs"
    else "${config.home.homeDirectory}/.local/share/tend/logs";

  # Build the full argument list for `tend daemon`.
  # `pull` is the reconciler default — fast-forwards clean repos every cycle.
  # `fetch` only matters when pull is off (operator opted into fetch-only mode);
  # tend's binary treats pull as a strict superset of fetch.
  daemonArgs =
    ["daemon" "--interval" (toString cfg.interval)]
    ++ optionals cfg.quiet ["--quiet"]
    ++ optionals (cfg.workspace != null) ["--workspace" cfg.workspace]
    ++ ["--pull" (if cfg.pull then "true" else "false")]
    ++ ["--fetch" (if cfg.fetch then "true" else "false")]
    ++ ["--max-inflight" (toString cfg.maxInflight)]
    ++ optionals (cfg.githubTokenFile != null) ["--github-token-file" cfg.githubTokenFile];

  flakeUpdateArgs =
    ["flake-update-daemon"
     "--min-interval" (toString fcfg.minInterval)
     "--max-interval" (toString fcfg.maxInterval)]
    ++ optionals fcfg.quiet ["--quiet"]
    ++ optionals (fcfg.workspace != null) ["--workspace" fcfg.workspace]
    ++ optionals (fcfg.githubTokenFile != null) ["--github-token-file" fcfg.githubTokenFile];

  # `tend prebuild-daemon` — sibling of flake-update-daemon. Walks each
  # workspace, builds repos whose HEAD has moved since last cycle,
  # optionally pushes the resulting closures to an Attic cache. The
  # systemd/launchd unit applies resource caps so the daemon stays a
  # background citizen on a shared host.
  prebuildArgs =
    ["prebuild-daemon"
     "--min-interval" (toString pcfg.minInterval)
     "--max-interval" (toString pcfg.maxInterval)
     "--max-inflight" (toString pcfg.maxInflight)]
    ++ optionals pcfg.quiet ["--quiet"]
    ++ optionals (pcfg.workspace != null) ["--workspace" pcfg.workspace]
    ++ optionals (pcfg.atticCache != null) ["--attic-cache" pcfg.atticCache]
    ++ optionals (pcfg.atticServer != null) ["--attic-server" pcfg.atticServer]
    ++ optionals (pcfg.atticUrl != null) ["--attic-url" pcfg.atticUrl]
    ++ optionals (pcfg.atticTokenFile != null) ["--attic-token-file" pcfg.atticTokenFile];

  # Paths to binaries the tend daemons shell out to (nix, git, gh, etc.).
  # launchd and systemd don't inherit the user's interactive shell PATH,
  # so we give them an explicit one that covers:
  #   - /run/current-system/sw/bin       (nix-darwin system profile — nix)
  #   - /etc/profiles/per-user/$USER/bin (home-manager profile — git, gh,
  #                                       and any other CLI installed via HM)
  #   - /nix/var/nix/profiles/default/bin (global default profile)
  #   - /usr/bin, /bin                    (stock OS utilities — /bin/sh etc.)
  #
  # Both the reconcile daemon and the flake-update daemon use the same
  # PATH — the reconcile daemon invokes `gh auth git-credential` via git's
  # credential helper chain, so missing `gh` shows up in `tend report` as
  # `pull failed — gh: command not found`. One shared PATH constant
  # ensures both daemons stay in sync.
  tendPath =
    if isDarwin
    then "/run/current-system/sw/bin:/etc/profiles/per-user/${config.home.username}/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    else "/run/current-system/sw/bin:/etc/profiles/per-user/${config.home.username}/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin";

  flakeUpdateEnv =
    {
      PATH = tendPath;
      HOME = config.home.homeDirectory;
    }
    // fcfg.extraEnv;

  daemonEnv =
    {
      PATH = tendPath;
      HOME = config.home.homeDirectory;
    }
    // cfg.extraEnv;

  prebuildEnv =
    {
      PATH = tendPath;
      HOME = config.home.homeDirectory;
    }
    // pcfg.extraEnv;
in {
  options.services.tend.daemon = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the tend daemon — a workspace reconciler that drives
        the on-disk state toward the org's current state on a fixed
        interval. Each cycle (when pull=true) is one scheduler-driven
        reconcile pass: per-repo SyncRepoJob → PullRepoJob via Dag
        edges, bounded by the `maxInflight` per-kind Budget, with
        Exponential retry for transient invocation errors and an
        Exponential reaction wave for the "no such ref" pull-failure
        class.

        Side products written under ~/.local/share/tend (XDG_DATA_HOME):
          - audit.jsonl                — high-level domain events
                                          (pull_completed, watch_event)
          - scheduler-transitions.jsonl — every FSM transition the
                                          scheduler emits
          - drift-events.jsonl          — typed DriftEvents (stub-
                                          directory, dirty-tree,
                                          pull-failed, etc.)

        Operators read all three via `tend report` + `tend doctor`.

        Configurable via `pull`, `fetch`, `maxInflight` (substrate
        knobs) and `interval`, `quiet`, `workspace` (operational knobs).
      '';
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

    pull = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Fast-forward clean repos every cycle (`git pull --ff-only`). This
        is the reconciler behavior — drives the workspace toward the
        org's current state continuously. Pull subsumes fetch (the
        underlying `git pull --ff-only` does its own fetch), so when
        `pull` is true the `fetch` setting is a no-op. Set to false to
        leave clean repos exactly where the operator parked them
        (operator runs `tend pull` manually when desired).
      '';
    };

    fetch = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Plain `git fetch --all --prune` each cycle. Only takes effect when
        `pull` is false. Kept so a fetch-only daemon remains expressible
        and so legacy operators who relied on the old fetch-only behavior
        can opt back into it explicitly (`pull = false; fetch = true;`).
      '';
    };

    maxInflight = mkOption {
      type = types.int;
      default = 16;
      description = ''
        Maximum concurrent `git pull` Jobs per workspace per cycle.
        Bounds the shigoto-scheduler's per-kind Budget for the
        `tend.pull-repo` kind so a workspace with hundreds of repos
        doesn't saturate file handles, SSH connection multiplexers, or
        network sockets. 16 is conservative for typical broadband; tune
        upward if reconcile latency matters more than per-pull
        reliability, downward if SSH/Multiplexer collisions surface in
        the transition log.

        Substrate path: this flag passes through to
        `reconcile_workspace_sync_then_pull(workspace, repos, max_inflight, ...)`
        which installs a `BudgetSpec::max_concurrent(N)` against
        `tend.pull-repo`, `tend.sync-repo`, and `tend.fetch-repo` kinds.
      '';
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

  options.services.tend.prebuild = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the tend prebuild daemon — runs `tend prebuild-daemon`
        as a launchd (Darwin) or systemd (Linux) service. The daemon
        walks every workspace, builds repos whose HEAD has moved since
        last cycle, and (if `atticCache` is set) pushes each resulting
        closure to the Attic binary cache via `attic push <cache>
        <out-path>`. Pairs with `services.tend.daemon` (which pulls)
        and `services.tend.flakeUpdate` (which propagates lock bumps)
        to form the full reconcile-then-build-then-cache loop:

          tend.daemon       — every 5 min, git pull every workspace repo
          tend.flakeUpdate  — exp-backoff propagate flake.lock bumps
          tend.prebuild     — exp-backoff build new HEADs + push closures

        Sleep interval doubles on converged cycles (zero builds) up to
        `maxInterval`; any successful build resets to `minInterval`.

        Per-cycle parallelism is capped by `maxInflight` (default 1
        for shared workstations; raise to 2-4 on a dedicated build
        host like rio). Resource ceilings are best enforced via the
        systemd/launchd unit's CPUQuota/MemoryHigh/IOWeight (see
        rio's wiring for an example) — keeping the daemon a
        background citizen on a shared host.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.tend;
      description = "Tend package providing the tend binary";
    };

    minInterval = mkOption {
      type = types.int;
      default = 120;
      description = ''
        Minimum sleep between cycles (seconds). Default 120s is more
        conservative than flake-update (60s) because each prebuild
        cycle can kick off many `nix build` invocations.
      '';
    };

    maxInterval = mkOption {
      type = types.int;
      default = 3600;
      description = "Maximum sleep between cycles when converged (seconds).";
    };

    maxInflight = mkOption {
      type = types.int;
      default = 1;
      description = ''
        Maximum concurrent `nix build` invocations per cycle. Each
        build still parallelises internally per `max-jobs`, so 1 is
        a safe default. Raise to 2-4 on dedicated builders.
      '';
    };

    workspace = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Limit to a specific workspace by name (null = all workspaces).";
    };

    quiet = mkOption {
      type = types.bool;
      default = true;
      description = "Suppress per-step output (recommended for daemon mode).";
    };

    atticCache = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "nexus";
      description = ''
        Attic cache name to push built closures to. If null, prebuild
        builds without pushing (closures still land in /nix/store and
        get swept by the periodic `attic-store-push` timer).
      '';
    };

    atticServer = mkOption {
      type = types.nullOr types.str;
      default = "nexus";
      description = "Attic server alias for `attic login`.";
    };

    atticUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "http://rio:8080/";
      description = "Attic server URL. Required when atticCache is set.";
    };

    atticTokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/attic/jwt/token";
      description = ''
        Path to a file containing the Attic JWT token. SOPS-managed
        on pleme-io clusters (`attic/jwt/token`). Required when
        atticCache is set.
      '';
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = ''
        Extra environment variables to set on the prebuild daemon's
        launchd/systemd service, merged on top of the defaults
        (PATH, HOME).
      '';
    };

    # Resource caps — passed straight through to the systemd unit's
    # `Service` section. Defaults size for rio (16C/32T, 32 GB RAM)
    # but every host overrides; the systemd defaults if unset are
    # "no limit", which is fine for dedicated builders.
    cpuQuota = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "400%";
      description = ''
        systemd `CPUQuota=` for the prebuild daemon unit (Linux only).
        Examples: `"400%"` = 4 of N cores, `"50%"` = half a core.
        Null = no quota (use the whole host).
      '';
    };

    memoryHigh = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "8G";
      description = ''
        systemd `MemoryHigh=` for the prebuild daemon unit (Linux only).
        Kernel begins throttling above this; soft cap, not OOM.
        Null = no cap.
      '';
    };

    memoryMax = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "16G";
      description = ''
        systemd `MemoryMax=` (hard limit; OOM-kills above this).
        Null = no cap.
      '';
    };

    ioWeight = mkOption {
      type = types.nullOr types.int;
      default = null;
      example = 50;
      description = ''
        systemd `IOWeight=` (1-10000, default 100). Lower than 100
        deprioritises the daemon's disk I/O behind interactive work.
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

    # Linux: prebuild daemon + resource caps + logrotate config
    (mkIf (pcfg.enable && !isDarwin) (mkMerge [
      {
        home.activation.tend-prebuild-log-dir = lib.hm.dag.entryAfter ["writeBoundary"] ''
          run mkdir -p "${logDir}"
        '';
      }

      (mkSystemdService {
        name = "tend-prebuild";
        description = "Tend prebuild daemon — build new HEADs + push closures to Attic";
        command = "${pcfg.package}/bin/tend";
        args = prebuildArgs;
        env = prebuildEnv;
      })

      # Augment the Service block produced by mkSystemdService with
      # resource caps. None of these are set unless the operator
      # explicitly opts in via the corresponding `services.tend.prebuild.*`
      # option, so the default behaviour matches the other tend daemons.
      {
        systemd.user.services.tend-prebuild.Service =
          (optionalAttrs (pcfg.cpuQuota != null) {
            CPUQuota = pcfg.cpuQuota;
          })
          // (optionalAttrs (pcfg.memoryHigh != null) {
            MemoryHigh = pcfg.memoryHigh;
          })
          // (optionalAttrs (pcfg.memoryMax != null) {
            MemoryMax = pcfg.memoryMax;
          })
          // (optionalAttrs (pcfg.ioWeight != null) {
            IOWeight = toString pcfg.ioWeight;
          });
      }

      {
        home.file.".config/logrotate.d/tend-prebuild".text = ''
          ${logDir}/tend-prebuild.log ${logDir}/tend-prebuild.err {
              size ${pcfg.logRotation.maxSize}
              rotate ${toString pcfg.logRotation.keep}
              ${optionalString pcfg.logRotation.compress "compress"}
              missingok
              notifempty
              copytruncate
          }
        '';
      }
    ]))

    # Darwin: prebuild daemon + log rotation (no resource caps — launchd
    # exposes a different vocabulary; add Niceness/ResourceLimits if
    # ever needed)
    (mkIf (pcfg.enable && isDarwin) (mkMerge [
      {
        home.activation.tend-prebuild-log-dir = lib.hm.dag.entryAfter ["writeBoundary"] ''
          run mkdir -p "${logDir}"
        '';
      }

      (mkLaunchdService {
        name = "tend-prebuild";
        label = "io.pleme.tend-prebuild";
        command = "${pcfg.package}/bin/tend";
        args = prebuildArgs;
        env = prebuildEnv;
        logDir = logDir;
      })

      {
        home.file.".local/share/tend/newsyslog.d/tend-prebuild.conf".text = let
          logFile = "${logDir}/tend-prebuild.log";
          errFile = "${logDir}/tend-prebuild.err";
          count = toString pcfg.logRotation.keep;
          size = let
            raw = pcfg.logRotation.maxSize;
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
            if pcfg.logRotation.compress
            then "GN"
            else "N";
        in ''
          # logfilename          [owner:group]  mode  count  size  when  flags
          ${logFile}                             644   ${count}    ${size}  *     ${flags}
          ${errFile}                             644   ${count}    ${size}  *     ${flags}
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
        description = "Tend workspace daemon — sync + pull repos (reconciler)";
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
