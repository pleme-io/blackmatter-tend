# blackmatter-tend/nixos — system-level NixOS module for the tend stack.
#
# Sibling of the HM module at ../module/default.nix. The HM module wires
# tend as user-level daemons under a developer's account ($HOME-relative
# state, runs as the human user). This NixOS module wires the SAME three
# daemons as **system services** running under a dedicated `tend`
# system user, with state under /var/lib/tend. Use this when:
#
#   - The host's job is to populate a cache for the whole fleet
#     (e.g. rio's `nexus` Attic), and the cache-warming should not
#     be tied to one human's login state or workspace dirty-tree.
#   - You want a clean security boundary: token files owned by
#     `tend:tend`, no developer-account secrets in the daemon's reach.
#   - You want declarative resource caps (CPUQuota, MemoryHigh,
#     MemoryMax, IOWeight) enforced by system systemd, not user
#     systemd (the system manager is the one that actually enforces
#     `MemoryMax` against cgroup OOM under load).
#
# The two module flavours can coexist on the same host — a developer
# user may keep their HM `services.tend.daemon` for in-tree dev pulls,
# while the system module owns a separate `/var/lib/tend/workspace`
# clone used by the cache-warming prebuild loop. Each instance has
# its own audit log + seen-cache, so they don't trample state.

{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.tend;

  # Default tend package — operators can override per-host. Picked
  # via inputs.tend.packages on the consumer flake; we look it up
  # under pkgs to avoid taking an `inputs` argument here.
  tendPackage =
    if cfg.package != null
    then cfg.package
    else pkgs.tend or pkgs.pleme-tend;

  # PATH the daemons need. We don't inherit any user PATH because
  # this is a system unit; spell out everything `tend`'s subprocesses
  # may exec (nix, git, gh, attic).
  systemPath =
    "${pkgs.nix}/bin:${pkgs.git}/bin:${pkgs.openssh}/bin:"
    + "${pkgs.gnused}/bin:${pkgs.coreutils}/bin:/run/current-system/sw/bin";

  daemonArgs =
    [ "daemon" "--interval" (toString cfg.daemon.interval) ]
    ++ optionals cfg.daemon.quiet [ "--quiet" ]
    ++ optionals (cfg.daemon.workspace != null)
      [ "--workspace" cfg.daemon.workspace ]
    ++ [ "--pull" (if cfg.daemon.pull then "true" else "false") ]
    ++ [ "--fetch" (if cfg.daemon.fetch then "true" else "false") ]
    ++ [ "--max-inflight" (toString cfg.daemon.maxInflight) ]
    ++ optionals (cfg.githubTokenFile != null)
      [ "--github-token-file" cfg.githubTokenFile ];

  flakeUpdateArgs =
    [ "flake-update-daemon"
      "--min-interval" (toString cfg.flakeUpdate.minInterval)
      "--max-interval" (toString cfg.flakeUpdate.maxInterval) ]
    ++ optionals cfg.flakeUpdate.quiet [ "--quiet" ]
    ++ optionals (cfg.flakeUpdate.workspace != null)
      [ "--workspace" cfg.flakeUpdate.workspace ]
    ++ optionals (cfg.githubTokenFile != null)
      [ "--github-token-file" cfg.githubTokenFile ];

  prebuildArgs =
    [ "prebuild-daemon"
      "--min-interval" (toString cfg.prebuild.minInterval)
      "--max-interval" (toString cfg.prebuild.maxInterval)
      "--max-inflight" (toString cfg.prebuild.maxInflight) ]
    ++ optionals cfg.prebuild.quiet [ "--quiet" ]
    ++ [ "--packages" cfg.prebuild.packages
         "--repro" cfg.prebuild.repro ]
    ++ optionals (cfg.prebuild.workspace != null)
      [ "--workspace" cfg.prebuild.workspace ]
    ++ optionals (cfg.prebuild.atticCache != null)
      [ "--attic-cache" cfg.prebuild.atticCache ]
    ++ optionals (cfg.prebuild.atticServer != null)
      [ "--attic-server" cfg.prebuild.atticServer ]
    ++ optionals (cfg.prebuild.atticUrl != null)
      [ "--attic-url" cfg.prebuild.atticUrl ]
    ++ optionals (cfg.atticTokenFile != null)
      [ "--attic-token-file" cfg.atticTokenFile ];

  # Render the tend YAML config that the system daemons read.
  # Operators may supply their own config via `cfg.configFile`;
  # otherwise we synthesise one from `cfg.workspaces`. The
  # synthesised version sets `discover: true` so the org's
  # repos are picked up via GitHub API, plus tend's defaults
  # for the other knobs.
  generatedConfig = pkgs.writeText "tend-system-config.yaml" (
    builtins.toJSON {
      workspaces = map (ws: {
        name = ws.name;
        provider = ws.provider;
        base_dir = ws.baseDir;
        clone_method = ws.cloneMethod;
        discover = ws.discover;
      } // optionalAttrs (ws.org != null) { org = ws.org; })
        cfg.workspaces;
    });
  effectiveConfig =
    if cfg.configFile != null
    then cfg.configFile
    else generatedConfig;

  # All system daemons share an environment block — PATH spelled out,
  # HOME=stateDir so XDG_* defaults land in /var/lib/tend/{cache,share},
  # GH_CONFIG_DIR pointed at a tend-owned spot so gh CLI works.
  # NB: NixOS's systemd module also injects a default PATH onto every
  # unit's `environment`, so we use `lib.mkForce` to make ours win
  # (the default doesn't include `nix`/`git`, which the daemons need).
  systemEnv = {
    PATH = lib.mkForce systemPath;
    HOME = cfg.stateDir;
    XDG_CACHE_HOME = "${cfg.stateDir}/cache";
    XDG_DATA_HOME = "${cfg.stateDir}/share";
    XDG_CONFIG_HOME = "${cfg.stateDir}/config";
    GH_CONFIG_DIR = "${cfg.stateDir}/config/gh";
  };

  mkUnit = { description, args, extraServiceConfig ? {} }: {
    description = description;
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = systemEnv;
    serviceConfig = {
      Type = "simple";
      User = cfg.user;
      Group = cfg.group;
      StateDirectory = "tend";
      StateDirectoryMode = "0750";
      WorkingDirectory = cfg.stateDir;
      ExecStart =
        "${tendPackage}/bin/tend "
        + lib.concatStringsSep " " args
        + " --config ${effectiveConfig}";
      Restart = "on-failure";
      RestartSec = 5;

      # Light hardening — full hardening would block nix builds,
      # so this is the conservative middle ground.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [ cfg.stateDir "/nix/var/nix" ];
    } // extraServiceConfig;
  };

  workspaceType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        example = "pleme-io";
        description = "Workspace name (free-form; used by tend's audit log).";
      };
      provider = mkOption {
        type = types.str;
        default = "github";
        description = "Source provider — only `github` is currently supported by tend's discover loop.";
      };
      org = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "GitHub org to discover from. Defaults to `name` if null.";
      };
      baseDir = mkOption {
        type = types.str;
        example = "/var/lib/tend/workspace/pleme-io";
        description = "Absolute path tend clones repos into.";
      };
      cloneMethod = mkOption {
        type = types.enum [ "https" "ssh" ];
        default = "https";
        description = "How tend clones — `https` works with a token, `ssh` needs an agent.";
      };
      discover = mkOption {
        type = types.bool;
        default = true;
        description = "Auto-discover repos via the provider API.";
      };
    };
  };
in {
  options.services.tend = {
    enable = mkEnableOption ''
      Enable the tend stack as a system service. Creates a dedicated
      `tend` system user/group and wires the configured daemons
      (daemon, flakeUpdate, prebuild) as system systemd units running
      under that user.
    '';

    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = ''
        Tend package providing the `tend` binary. Defaults to
        `pkgs.tend` (or `pkgs.pleme-tend`) — override per-host when
        running a custom build.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "tend";
      description = "System user the daemons run as.";
    };

    group = mkOption {
      type = types.str;
      default = "tend";
      description = "Primary group for the tend user.";
    };

    uid = mkOption {
      type = types.int;
      default = 921;
      description = ''
        Static UID for the tend user. Pinned so per-host UIDs
        don't drift; pick a free slot below 1000 (system users).
      '';
    };

    gid = mkOption {
      type = types.int;
      default = 921;
      description = "Static GID for the tend group.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/tend";
      description = ''
        Root state directory owned by the tend user. Holds the
        workspace clones, audit logs, seen-cache, and shell
        config (XDG_*).
      '';
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "nix-trusted" ];
      description = ''
        Supplementary groups the tend user joins. Useful for
        granting access to host-side resources (e.g. a group
        with read on a shared workspace).
      '';
    };

    githubTokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/tend/github-token";
      description = ''
        Path to a file (mode 0400, owner `tend`) containing a
        GitHub token. Threaded into the pull + flake-update
        daemons so they can clone private repos + lift the
        unauthenticated rate limit.
      '';
    };

    atticTokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/tend/attic-token";
      description = ''
        Path to a file (mode 0400, owner `tend`) containing an
        Attic JWT token. Threaded into the prebuild daemon for
        `attic login` + `attic push`.
      '';
    };

    configFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a tend config YAML. If null, one is synthesised
        from the typed `workspaces` option below. Setting this
        is the escape hatch for advanced config (per-workspace
        `flake_deps`, watch, ai_tasks, etc.).
      '';
    };

    workspaces = mkOption {
      type = types.listOf workspaceType;
      default = [];
      example = lib.literalExpression ''
        [ { name = "pleme-io"; org = "pleme-io";
            baseDir = "/var/lib/tend/workspace/pleme-io"; } ]
      '';
      description = ''
        Declarative workspace list. Used to synthesise a YAML
        config when `configFile` is null. Each workspace clones
        into its own `baseDir`.
      '';
    };

    # ───────────────────── daemon (pull) ─────────────────────
    daemon = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Pull-and-reconcile cycle every `interval` seconds.";
      };
      interval = mkOption {
        type = types.int;
        default = 300;
        description = "Sync interval (seconds).";
      };
      workspace = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Limit to one workspace (null = all).";
      };
      pull = mkOption {
        type = types.bool;
        default = true;
        description = "Pull (`git pull --ff-only`) clean repos each cycle.";
      };
      fetch = mkOption {
        type = types.bool;
        default = true;
        description = "Plain `git fetch --all --prune` (only used when pull is false).";
      };
      maxInflight = mkOption {
        type = types.int;
        default = 16;
        description = "Concurrent pulls per cycle.";
      };
      quiet = mkOption {
        type = types.bool;
        default = true;
        description = "Suppress per-repo log lines.";
      };
      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "200%";
        description = "systemd CPUQuota for the daemon (pull) unit.";
      };
      memoryHigh = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "1G";
        description = "systemd MemoryHigh (soft throttle).";
      };
      memoryMax = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "2G";
        description = "systemd MemoryMax (hard OOM ceiling).";
      };
      ioWeight = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 60;
        description = "systemd IOWeight (lower de-prioritises behind interactive I/O).";
      };
    };

    # ───────────── flakeUpdate (lock propagation) ────────────
    flakeUpdate = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Run flake-update-daemon to propagate lock bumps.";
      };
      minInterval = mkOption {
        type = types.int;
        default = 60;
        description = "Reset interval after work (seconds).";
      };
      maxInterval = mkOption {
        type = types.int;
        default = 3600;
        description = "Max sleep when converged (seconds).";
      };
      workspace = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Limit to one workspace.";
      };
      quiet = mkOption {
        type = types.bool;
        default = true;
        description = "Suppress per-step output.";
      };
      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "200%";
        description = "systemd CPUQuota for the flake-update unit.";
      };
      memoryHigh = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "2G";
        description = "systemd MemoryHigh.";
      };
      memoryMax = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "3G";
        description = "systemd MemoryMax.";
      };
      ioWeight = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 70;
        description = "systemd IOWeight.";
      };
    };

    # ───────────── prebuild (cache-warming) ─────────────────
    prebuild = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Run prebuild-daemon — builds every workspace flake repo
          whose HEAD has moved since last cycle, optionally pushing
          each closure to an Attic cache. The cache-warming layer.
        '';
      };
      minInterval = mkOption {
        type = types.int;
        default = 60;
        description = "Reset interval after work (seconds).";
      };
      maxInterval = mkOption {
        type = types.int;
        default = 3600;
        description = "Max sleep when converged (seconds).";
      };
      maxInflight = mkOption {
        type = types.int;
        default = 2;
        description = "Concurrent `nix build` invocations.";
      };
      workspace = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Limit to one workspace.";
      };
      quiet = mkOption {
        type = types.bool;
        default = true;
        description = "Suppress per-step output.";
      };

      packages = mkOption {
        type = types.str;
        default = "all";
        example = "default";
        description = ''
          Which flake outputs to build per repo: "all" (every
          `packages.''${system}.*` — max cache coverage, the fill
          default), "default", or a comma-separated allow-list (e.g.
          "mado,tear"). Threaded to prebuild-daemon as `--packages`.
        '';
      };
      repro = mkOption {
        type = types.enum [ "trusting" "verify" ];
        default = "trusting";
        description = ''
          Reproducibility gate before a closure is pushed:
          "trusting" (fast — correct on Linux, where the build sandbox
          pins $NIX_BUILD_TOP so rustc's crate SVH is stable) or
          "verify" (`nix build --rebuild` byte-compare, push only if
          identical — ~1 extra build/package). Threaded as `--repro`.
          NOTE: darwin builds are NOT sandbox-deterministic (unstable
          SVH → cache poison), so darwin nodes must not push to a
          fleet-substituted cache regardless of this gate — see the
          2026-06-02 rio-poison incident.
        '';
      };

      atticCache = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "nexus";
        description = "Attic cache name to push closures to.";
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
        description = "Attic server URL.";
      };

      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "800%";
        description = "systemd CPUQuota for the prebuild unit.";
      };
      memoryHigh = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "12G";
        description = "systemd MemoryHigh (soft throttle).";
      };
      memoryMax = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "20G";
        description = "systemd MemoryMax (hard OOM ceiling).";
      };
      ioWeight = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 80;
        description = "systemd IOWeight (1-10000, default 100).";
      };
    };
  };

  config = mkIf cfg.enable {
    # ── tend system user + group ────────────────────────────
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      uid = cfg.uid;
      home = cfg.stateDir;
      createHome = true;
      homeMode = "0750";
      shell = pkgs.bashInteractive;
      description = "tend — workspace reconciler + cache warmer";
      extraGroups = cfg.extraGroups;
    };
    users.groups.${cfg.group} = {
      gid = cfg.gid;
    };

    # ── State + secret dirs created at activation ───────────
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir}                0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.stateDir}/cache          0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.stateDir}/share          0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.stateDir}/config         0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.stateDir}/workspace      0750 ${cfg.user} ${cfg.group} - -"
    ];

    # ── tend is a trusted Nix user so it can talk to nix-daemon ──
    nix.settings.trusted-users = [ cfg.user ];

    # ── Allow read of the secrets dir if a token is configured ──
    # The actual SOPS / external-secrets owner+mode flip lives at
    # the call site (e.g. nix repo's secrets module renders the
    # attic JWT to /run/secrets/tend/attic-token owned by `tend`).

    # ── Daemons ─────────────────────────────────────────────
    systemd.services."tend-system-daemon" = mkIf cfg.daemon.enable
      (mkUnit {
        description = "tend — workspace pull/reconcile (system, runs as ${cfg.user})";
        args = daemonArgs;
        extraServiceConfig =
          (optionalAttrs (cfg.daemon.cpuQuota != null) { CPUQuota = cfg.daemon.cpuQuota; })
          // (optionalAttrs (cfg.daemon.memoryHigh != null) { MemoryHigh = cfg.daemon.memoryHigh; })
          // (optionalAttrs (cfg.daemon.memoryMax != null) { MemoryMax = cfg.daemon.memoryMax; })
          // (optionalAttrs (cfg.daemon.ioWeight != null) { IOWeight = toString cfg.daemon.ioWeight; });
      });

    systemd.services."tend-system-flake-update" = mkIf cfg.flakeUpdate.enable
      (mkUnit {
        description = "tend — flake.lock propagation (system, runs as ${cfg.user})";
        args = flakeUpdateArgs;
        extraServiceConfig =
          (optionalAttrs (cfg.flakeUpdate.cpuQuota != null) { CPUQuota = cfg.flakeUpdate.cpuQuota; })
          // (optionalAttrs (cfg.flakeUpdate.memoryHigh != null) { MemoryHigh = cfg.flakeUpdate.memoryHigh; })
          // (optionalAttrs (cfg.flakeUpdate.memoryMax != null) { MemoryMax = cfg.flakeUpdate.memoryMax; })
          // (optionalAttrs (cfg.flakeUpdate.ioWeight != null) { IOWeight = toString cfg.flakeUpdate.ioWeight; });
      });

    systemd.services."tend-system-prebuild" = mkIf cfg.prebuild.enable
      (mkUnit {
        description = "tend — build new HEADs + push to Attic (system, runs as ${cfg.user})";
        args = prebuildArgs;
        extraServiceConfig =
          (optionalAttrs (cfg.prebuild.cpuQuota != null) {
            CPUQuota = cfg.prebuild.cpuQuota;
          })
          // (optionalAttrs (cfg.prebuild.memoryHigh != null) {
            MemoryHigh = cfg.prebuild.memoryHigh;
          })
          // (optionalAttrs (cfg.prebuild.memoryMax != null) {
            MemoryMax = cfg.prebuild.memoryMax;
          })
          // (optionalAttrs (cfg.prebuild.ioWeight != null) {
            IOWeight = toString cfg.prebuild.ioWeight;
          });
      });
  };
}
