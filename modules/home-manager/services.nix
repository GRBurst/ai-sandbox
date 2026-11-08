# Long-running sandboxed services: systemd user units that run an agent backend under nono
# (inside ai-sandbox-run while the isolation is on), each behind a compressing proxy that
# binds loopback unless `proxy.listenAddress` says otherwise.
# A service has one profile (inline, the same fields as a harness) emitted by
# ./profiles.nix with its backend port as `network.listen_port`, no alias, no `--allow-cwd`.
# Preset: `opencode-web` (off).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.aiSandbox;
  homeDir = config.home.homeDirectory;
  enabled = lib.filterAttrs (_: s: s.enable) cfg.services;

  nono = "${cfg.package}/bin/nono";

  # The namespace isolation around nono, as for the interactive aliases. No
  # --nono-alias (a unit has no nono-only twin) and no --open-urls-profile
  # (services never get the URL relay). The service's gitDirs as `--git-dir`, `$HOME`
  # expanded here: a unit has no shell.
  isolated = cfg.enable && cfg.isolation.enable;
  gitLayerOn = isolated && lib.elem "git" cfg.isolation.layers;
  expandHome = d:
    if lib.hasPrefix "$HOME/" d
    then homeDir + lib.removePrefix "$HOME" d
    else d;
  wrap = s:
    lib.optionals isolated
    (["${cfg.runPackage}/bin/ai-sandbox-run"]
      ++ lib.concatMap (d: ["--git-dir" (expandHome d)]) s.gitDirs
      ++ ["--"]);

  # ExecStart is joined with spaces rather than lib.escapeShellArgs: systemd
  # splits on whitespace itself, no argument here contains one, and the
  # unquoted form is what the coupling assertions read back.
  execLine = args: lib.concatStringsSep " " args;

  caddyfilePath = name: "${config.xdg.configHome}/agent-web/${name}/Caddyfile";

  # proxy.listenAddress: an IPv4 or IPv6 literal (no brackets, zone or port). 0.0.0.0 is the
  # one spelling of every interface; it gets no `bind` line, which is Caddy's default (Go
  # listens on every address, IPv4 and IPv6, for `:<port>` as for 0.0.0.0).
  octet = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";
  isIPv4 = a: builtins.match "${octet}[.]${octet}[.]${octet}[.]${octet}" a != null;
  isIPv6 = a: let
    halves = lib.splitString "::" a;
    groups = h: lib.optionals (h != "") (lib.splitString ":" h);
    gs = lib.concatMap groups halves;
  in
    builtins.match "[0-9A-Fa-f:]+" a
    != null
    && lib.all (g: builtins.match "[0-9A-Fa-f]{1,4}" g != null) gs
    && (
      if lib.length halves == 2
      then lib.length gs <= 7
      else lib.length halves == 1 && lib.length gs == 8
    );
  everyInterface = a: a == "0.0.0.0";
  isLoopback = a: a == "::1" || (isIPv4 a && lib.hasPrefix "127." a);

  bindLine = s: lib.optionalString (!everyInterface s.proxy.listenAddress) "\tbind ${s.proxy.listenAddress}\n";

  caddyfileFor = s: ''
    {
    	admin off
    	auto_https off
    }

    :${toString s.listenPort} {
    ${bindLine s}	encode zstd gzip
    	reverse_proxy 127.0.0.1:${toString s.backendPort} {
    		# Agent turns stream for minutes. flush_interval -1 disables
    		# response buffering, so tokens reach the browser as they are
    		# produced instead of in proxy-sized chunks.
    		flush_interval -1
    	}
    }
  '';

  proxyUnitOf = name: "${name}-proxy";

  mkProxyUnit = name: s: {
    Unit = {
      Description = let
        a = s.proxy.listenAddress;
      in
        if isLoopback a
        then "Compressing loopback proxy for ${name}"
        else if everyInterface a
        then "Compressing proxy for ${name} on every interface"
        else "Compressing proxy for ${name} on ${a}";
      # PartOf, not Requires: the proxy is pointless without its backend, but a
      # backend restart must not leave the proxy stopped.
      PartOf = ["${s.backendUnit}.service"];
      After = ["${s.backendUnit}.service"];
    };
    Service = {
      Type = "simple";
      ExecStart = "${s.proxy.package}/bin/caddy run --config ${caddyfilePath name} --adapter caddyfile";
      ExecReload = "${s.proxy.package}/bin/caddy reload --config ${caddyfilePath name} --adapter caddyfile --force";
      Restart = "always";
      RestartSec = 5;
    };
    Install.WantedBy = ["default.target"];
  };

  # A sandboxed unit. TMPDIR points at systemd's RuntimeDirectory rather than
  # the `''${TMPDIR:-...}` shell expression the interactive aliases use: a unit
  # has no shell to expand that, and %t/agent-web/<unit> is already private and
  # 0700. The profiles' inherited `$TMPDIR` grant then resolves there.
  #
  # nono runs inside ai-sandbox-run (`wrap` above). Its `session` layer hides
  # %t, i.e. /run/user/$UID, and binds this TMPDIR back, so the unit keeps its
  # own runtime dir and sees nothing else of the user's session sockets.
  #
  # nono refuses to start with
  #   CWD access requires --allow-cwd in non-interactive mode
  # unless the process's cwd is already covered by the profile. A user service
  # inherits $HOME as its cwd, which is NOT granted, so the unit names its
  # `workdir` (`--workdir`, not `--allow-cwd`: the working tree is decided
  # declaratively rather than taken from wherever the process happens to start).
  #
  # The backend unit Wants its proxy: PartOf on the proxy only propagates STOP, so
  # a switch that stops the backend leaves the proxy down unless the backend pulls
  # it back in.
  #
  # The unit names its profile but does not hold it, so a switch that changes only the profile
  # (or the base it extends) would leave the running service on its old grants. The sha256 of
  # each profile file of that chain that this module writes goes into `X-Restart-Triggers`:
  # the unit file changes with them and Home Manager restarts the unit.
  profileTriggers = name: let
    file = n: config.xdg.configFile."nono/profiles/${n}.json" or null;
    chain = n: let
      f = file n;
    in
      lib.optionals (f != null)
      (["${n}.json:${builtins.hashString "sha256" f.text}"]
        ++ lib.concatMap chain (lib.toList ((builtins.fromJSON f.text).extends or [])));
  in
    chain name;

  mkSandboxedUnit = name: s: unit: u: {
    Unit =
      {Description = u.description;}
      // u.extraUnit
      // {X-Restart-Triggers = (u.extraUnit.X-Restart-Triggers or []) ++ profileTriggers name;}
      // lib.optionalAttrs (s.proxy.enable && unit == s.backendUnit) {
        Wants = (u.extraUnit.Wants or []) ++ ["${proxyUnitOf name}.service"];
      };
    Service =
      {
        RuntimeDirectory = "agent-web/${unit}";
        RuntimeDirectoryMode = "0700";
        Environment =
          lib.mapAttrsToList (k: v: "${k}=${v}")
          ({
              PATH = lib.concatStringsSep ":" s.path;
              TMPDIR = "%t/agent-web/${unit}";
            }
            # Empty, not unset: a unit's Environment= overrides the user
            # manager's, so a relax token exported into the manager never
            # loosens a service's isolation.
            // lib.optionalAttrs isolated {AI_SANDBOX_RELAX = "";}
            // u.env);
        WorkingDirectory = s.workdir;
        ExecStart = execLine (wrap s
          ++ [
            nono
            "run"
            "--profile"
            name
            "--workdir"
            s.workdir
            "--strict-broker-path"
            "--silent"
            "--"
          ]
          ++ u.exec);
      }
      // u.extraService;
    Install.WantedBy = ["default.target"];
  };

  unitsOf = name: s:
    lib.mapAttrs (mkSandboxedUnit name s) s.units
    // lib.optionalAttrs s.proxy.enable {${proxyUnitOf name} = mkProxyUnit name s;};

  allPorts = lib.concatMap (s: [s.listenPort s.backendPort]) (lib.attrValues enabled);

  # Every unit name the enabled services ask for, the proxies included; `unitsOf` merges them
  # with `//`, so a duplicate would silently replace a unit.
  requestedUnits = lib.concatLists (lib.mapAttrsToList (name: s:
    lib.attrNames s.units ++ lib.optional s.proxy.enable (proxyUnitOf name))
  enabled);
  duplicateUnits = lib.unique (lib.filter (u: lib.count (x: x == u) requestedUnits > 1) requestedUnits);

  # The service profile is named after the service and shares the profile emitter with the
  # harnesses (./profiles.nix): a service may not take a harness command or any harness or
  # variant profile name.
  harnessNames =
    lib.attrNames cfg.harnessProfiles
    ++ lib.attrValues cfg.harnessProfiles
    ++ map (v: v.profile) (lib.attrValues cfg.internal.variants);
  clashingNames = lib.filter (n: lib.elem n harnessNames) (lib.attrNames enabled);

  # workdir is WorkingDirectory= (no $HOME expansion there) and an ExecStart argument, which
  # is joined with spaces; dataDirs go into `install -d "<dir>"` at activation unescaped, so
  # only a leading $HOME may expand there.
  goodWorkdir = d: builtins.match "/[^[:space:]$%\"'\\]*" d != null;
  goodDataDir = d: builtins.match "(/|[$]HOME/)[^$\"`\\]*" d != null;
  goodArg = a: builtins.match ".*[[:space:]].*" a == null;
  goodGitDir = d: (lib.hasPrefix "/" d || lib.hasPrefix "$HOME/" d) && goodWorkdir (expandHome d);

  serviceAssertions = name: s: let
    opt = "programs.aiSandbox.services.${name}";
    badArgs = lib.filterAttrs (_: u: !(lib.all goodArg u.exec)) s.units;
    badDirs = lib.filter (d: !(goodDataDir d)) s.dataDirs;
    badGitDirs = lib.filter (d: !(goodGitDir d)) s.gitDirs;
  in
    [
      {
        assertion = s.gitDirs == [] || gitLayerOn;
        message = ''
          ai-sandbox: ${opt}.gitDirs needs the namespace isolation's git layer, which alone holds
          them read-only. Turn on isolation.enable with "git" in isolation.layers, or drop gitDirs.
        '';
      }
      {
        assertion = badGitDirs == [];
        message = ''
          ai-sandbox: ${opt}.gitDirs entries must be absolute or start with $HOME/, without
          whitespace, `%`, quotes, backslashes or any other `$` (each is an ExecStart argument),
          got ${builtins.toJSON badGitDirs}.
        '';
      }
      {
        assertion = !s.proxy.enable || isIPv4 s.proxy.listenAddress || isIPv6 s.proxy.listenAddress;
        message = ''
          ai-sandbox: ${opt}.proxy.listenAddress must be an IPv4 or IPv6 address without
          brackets, zone or port ("127.0.0.1", the default, for this machine only; "0.0.0.0"
          for every interface), got "${s.proxy.listenAddress}".
        '';
      }
      {
        assertion = !s.proxy.enable || s.units ? ${s.backendUnit};
        message = ''
          ai-sandbox: ${opt}.backendUnit = "${s.backendUnit}" names none of its units
          (${builtins.toJSON (lib.attrNames s.units)}): its proxy would be ordered against a unit
          that does not exist and never be pulled in by it.
        '';
      }
      {
        assertion = goodWorkdir s.workdir;
        message = ''
          ai-sandbox: ${opt}.workdir must be an absolute path without whitespace, `$`, `%`,
          quotes or backslashes (it is WorkingDirectory= and an ExecStart argument), got "${s.workdir}".
        '';
      }
      {
        assertion = badDirs == [];
        message = ''
          ai-sandbox: ${opt}.dataDirs must be absolute or $HOME/-prefixed paths without
          quotes, backticks, backslashes or any other `$` (they are created by a double-quoted
          activation line), got ${builtins.toJSON badDirs}.
        '';
      }
    ]
    ++ lib.mapAttrsToList (unit: u: {
      assertion = false;
      message = ''
        ai-sandbox: ${opt}.units.${unit}.exec arguments must not contain whitespace (ExecStart
        is joined with spaces), got ${builtins.toJSON u.exec}.
      '';
    })
    badArgs;

  unitType = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = "The unit's Description.";
      };
      exec = lib.mkOption {
        type = with lib.types; listOf str;
        description = "The command nono runs inside the sandbox (argv, joined with spaces).";
      };
      env = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = {};
        description = "Extra Environment= entries (PATH, TMPDIR and AI_SANDBOX_RELAX are set by the module).";
      };
      extraUnit = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Extra [Unit] settings (ordering against the service's other units).";
      };
      extraService = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Extra [Service] settings (Type, Restart, ExecStartPre, ...).";
      };
    };
  };

  serviceType = lib.types.submodule ({name, ...}: {
    options = {
      enable = lib.mkEnableOption "the service ${name}";
      profile = lib.mkOption {
        type = lib.types.submodule {options = import ./profile-options.nix {inherit lib;};};
        description = ''
          The service's nono profile (named after the service): the same fields as a harness.
          A service has no --allow-cwd, so the tree it works in (`workdir`) has to be granted here.
        '';
      };
      listenPort = lib.mkOption {
        type = lib.types.port;
        description = "Port the proxy listens on, the one a browser connects to. Never opened in a firewall by this module.";
      };
      backendPort = lib.mkOption {
        type = lib.types.port;
        description = "Loopback port the backend binds; the profile's only `network.listen_port`.";
      };
      workdir = lib.mkOption {
        type = lib.types.str;
        default = lib.replaceStrings ["$HOME"] [homeDir] cfg.projectsDir;
        defaultText = lib.literalExpression ''programs.aiSandbox.projectsDir with $HOME expanded'';
        description = "Absolute working tree of the sandboxed units (`--workdir`); the profile must grant it.";
      };
      path = lib.mkOption {
        type = with lib.types; listOf str;
        # The standard NixOS user set without the user's own writable dirs. `nono
        # --strict-broker-path` refuses to start when any PATH entry is writable from
        # inside the sandbox -- otherwise a sandboxed agent could drop its own `git` on
        # the PATH and have the broker run it outside the sandbox.
        default = [
          "/run/wrappers/bin"
          "/etc/profiles/per-user/${config.home.username}/bin"
          "/run/current-system/sw/bin"
        ];
        description = "PATH of the sandboxed units; must contain nothing the sandbox can write.";
      };
      units = lib.mkOption {
        type = lib.types.attrsOf unitType;
        default = {};
        description = "The sandboxed systemd user units of the service, by unit name.";
      };
      backendUnit = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "The unit that binds `backendPort`: the proxy is ordered against it and it Wants the proxy.";
      };
      gitDirs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        example = ["$HOME/projects/config.git"];
        description = ''
          Git directories below the service's grants whose hooks and config must not be
          written from inside, such as a bare repository of your config files under `workdir`:
          the isolation wrapper holds each one read-only as for a variant's `gitDirs` (`hooks/`,
          `config`, `config.worktree`, `info/`, in-tree config includes, its linked worktrees'
          `config.worktree`, `commondir` and `gitdir`); objects and refs stay writable. Grants
          nothing. Absolute or `$HOME/...` (expanded when the unit is built). The wrapper refuses
          to start, and the unit fails (fail closed), while one is missing, has no `hooks/` or
          has a `commondir` file. Needs the namespace isolation with its `git` layer.
        '';
      };
      dataDirs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        description = ''
          Absolute directories created 0700 at activation (`agentWebDirs`): nono silently drops
          a grant whose path does not exist.
        '';
      };
      proxy = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Front the backend with a compressing Caddy proxy on `listenPort`.";
        };
        listenAddress = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
          description = ''
            Address the proxy binds (Caddy's `bind`), an IPv4 or IPv6 address without brackets,
            zone or port. The default serves this machine only. `"0.0.0.0"` is the one spelling
            of every interface (IPv4 and IPv6, Caddy's default bind): it exposes the agent to
            whatever reaches `listenPort`, so set it only behind a firewall you control.
          '';
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.caddy;
          defaultText = lib.literalExpression "pkgs.caddy";
          description = "Package providing the reverse proxy that terminates the browser connection.";
        };
      };
    };
  });

  # Per-leaf mkDefault, so a consumer overrides one field without restating the rest.
  defaults = lib.mapAttrs (_: lib.mkDefault);
  ocPort = cfg.services.opencode-web.backendPort;
in {
  options.programs.aiSandbox = {
    projectsDir = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/projects";
      description = "The services' static work tree (`$HOME`-relative spelling, as nono expands it).";
    };

    services = lib.mkOption {
      type = lib.types.attrsOf serviceType;
      default = {};
      description = ''
        Long-running agent backends as sandboxed systemd user units behind a loopback proxy.
        Listen and backend ports must be pairwise distinct across the enabled services.
      '';
    };

    serviceUnits = lib.mkOption {
      type = with lib.types; attrsOf (listOf str);
      readOnly = true;
      description = ''
        Every enabled service mapped to the names of the systemd user units it generates
        (its own units and, with the proxy on, `<name>-proxy`). Read-only: for runtime
        verifiers that must test the units that actually exist.
      '';
    };
  };

  config = lib.mkMerge [
    {
      programs.aiSandbox.serviceUnits = lib.mapAttrs (n: s: lib.attrNames (unitsOf n s)) enabled;

      programs.aiSandbox.services.opencode-web =
        defaults {
          # Not 12345, which stays a general-purpose serving port.
          listenPort = 15434;
          backendPort = 15435;
        }
        // {
          # Reaches Claude like the opencode harness preset: through the Claude Code config
          # dir of opencode's own that its base sets and grants (shared with the harness, so
          # one login serves both); nothing under ~/.claude.
          profile = defaults {
            pack = "nolabs-ai/opencode";
            exclude = ["user_caches_linux"];
            allow = [cfg.projectsDir];
            readsSharedSkills = true;
          };
          units.opencode-web = defaults {
            description = "opencode web UI server";
            # Loopback only: the proxy is the only entry point.
            exec = ["opencode" "serve" "--port" (toString ocPort) "--hostname" "127.0.0.1"];
            extraService = {
              Type = "simple";
              Restart = "always";
              RestartSec = 5;
            };
          };
        };
    }

    (lib.mkIf (enabled != {}) {
      assertions =
        [
          {
            assertion = lib.length (lib.unique allPorts) == lib.length allPorts;
            message = ''
              ai-sandbox: services' listen and backend ports must be pairwise distinct, got
              ${builtins.toJSON allPorts}. Two services sharing a port fail at bind time, in
              whichever order systemd happens to start them.
            '';
          }
          {
            assertion = cfg.enable;
            message = ''
              ai-sandbox: programs.aiSandbox.services require programs.aiSandbox.enable. A
              service exposes an agent with full tool access to whatever reaches its port; the
              nono profile is the only boundary around it, so running one unsandboxed is not offered.
            '';
          }
          {
            assertion = clashingNames == [];
            message = ''
              ai-sandbox: service names must not be harness commands or profile names (the
              service profile is named after the service and would replace theirs), got
              ${builtins.toJSON clashingNames}.
            '';
          }
          {
            assertion = duplicateUnits == [];
            message = ''
              ai-sandbox: services' unit names (their units and `<name>-proxy`) must be distinct
              across the enabled services, got ${builtins.toJSON duplicateUnits} more than once.
            '';
          }
        ]
        ++ lib.concatLists (lib.mapAttrsToList serviceAssertions enabled);

      # nono drops a filesystem grant whose path does not exist -- silently, no
      # warning, no error. A directory the daemon would otherwise create on
      # first use therefore turns into a grant that quietly is not there, and
      # the failure surfaces later as an unexplained permission error inside the
      # sandbox. Create them before anything starts.
      home.activation.agentWebDirs =
        lib.hm.dag.entryAfter ["writeBoundary"]
        (lib.concatMapStringsSep "\n"
          (d: ''run install -d -m 0700 "${d}"'')
          (lib.concatMap (s: s.dataDirs) (lib.attrValues enabled)));

      xdg.configFile =
        lib.mapAttrs' (name: s: lib.nameValuePair "agent-web/${name}/Caddyfile" {text = caddyfileFor s;})
        (lib.filterAttrs (_: s: s.proxy.enable) enabled);

      systemd.user.services = lib.mkMerge (lib.mapAttrsToList unitsOf enabled);
    })
  ];
}
