# Long-running sandboxed services: the opencode-web preset and a
# generic service, over the standalone fixtures of ./lib.nix. Wired by ./default.nix as
# ai-sandbox-services.
{
  lib,
  pkgs,
  helpers,
}: let
  inherit (helpers) mkAssertionCheck aiFixtureWith aiNoNvf aiEmittedProfiles aiFailedWith aiFailsWith;
  home = "/tmp/ai-test";

  oc = {programs.aiSandbox.services.opencode-web.enable = true;};
  on = (aiFixtureWith oc).config;
  noIso =
    (aiFixtureWith {
      imports = [oc];
      programs.aiSandbox.isolation.enable = false;
    })
    .config;
  base = aiNoNvf.config;

  # A second, generic service: two sandboxed units, the backend not named after the service,
  # no proxy, a data dir.
  svcModule = {
    programs.aiSandbox.services.svc = {
      enable = true;
      listenPort = 15500;
      backendPort = 15501;
      backendUnit = "svc-server";
      proxy.enable = false;
      dataDirs = ["${home}/.svc"];
      profile = {
        pack = "nolabs-ai/claude";
        allow = ["$HOME/projects" "$HOME/.svc"];
      };
      units = {
        svc-daemon = {
          description = "svc daemon";
          exec = ["${pkgs.hello}/bin/hello"];
        };
        svc-server = {
          description = "svc server";
          exec = ["${pkgs.hello}/bin/hello" "--serve"];
          env.SVC_PORT = "15501";
          extraUnit.After = ["svc-daemon.service"];
        };
      };
    };
  };
  both = (aiFixtureWith {imports = [oc svcModule];}).config;

  units = h: h.systemd.user.services;
  exec = h: n: let
    v = (units h).${n}.Service.ExecStart or "";
  in
    if lib.isList v
    then lib.concatStringsSep " " v
    else v;
  envOf = h: n: (units h).${n}.Service.Environment or [];
  caddyfile = h: n: h.xdg.configFile."agent-web/${n}/Caddyfile".text or "";
  wrap = h: "${h.programs.aiSandbox.runPackage}/bin/ai-sandbox-run -- ";
  nono = h: "${h.programs.aiSandbox.package}/bin/nono";
  sandboxed = ["opencode-web" "svc-daemon" "svc-server"];

  # Per-pack defaults on a service profile: a delta on the service's pack reaches it.
  withDelta =
    (aiFixtureWith {
      imports = [oc];
      programs.aiSandbox.packDefaults."nolabs-ai/opencode" = {
        allowFile = ["$HOME/.pack-delta"];
        setVars.PACK_DELTA = "1";
      };
    })
    .config;
  ps = aiEmittedProfiles on;

  # A one-unit service without a proxy, named `name`, on ports `port` and `port + 1`.
  bare = name: port: {
    programs.aiSandbox.services.${name} = {
      enable = true;
      listenPort = port;
      backendPort = port + 1;
      proxy.enable = false;
      profile.pack = "nolabs-ai/claude";
      units.${name} = {
        description = name;
        exec = ["${pkgs.hello}/bin/hello"];
      };
    };
  };

  # The preset's proxy on another listen address.
  listening = addr:
    (aiFixtureWith {
      imports = [oc];
      programs.aiSandbox.services.opencode-web.proxy.listenAddress = addr;
    })
    .config;
  proxyDescription = h: (units h).opencode-web-proxy.Unit.Description;
  # The site block of the opencode-web Caddyfile up to its encode line.
  siteHead = h: let
    after = lib.splitString ":15434 {\n" (caddyfile h "opencode-web");
    parts =
      if lib.length after == 2
      then lib.splitString "\tencode zstd gzip\n" (lib.elemAt after 1)
      else [];
  in
    if lib.length parts == 2
    then lib.head parts
    else null;
  badListen = addr:
    aiFailsWith "ai-sandbox: programs.aiSandbox.services.opencode-web.proxy.listenAddress" {
      imports = [oc];
      programs.aiSandbox.services.opencode-web.proxy.listenAddress = addr;
    };

  # The preset with its ports and proxy package overridden leaf by leaf.
  fakeCaddy = pkgs.writeShellScriptBin "caddy" "exit 0";
  overridden =
    (aiFixtureWith {
      imports = [oc];
      programs.aiSandbox.services.opencode-web = {
        listenPort = 16001;
        backendPort = 16000;
        proxy.package = fakeCaddy;
      };
    })
    .config;
in
  mkAssertionCheck "ai-sandbox-services" [
    {
      condition =
        !(base.programs.aiSandbox.services.opencode-web.enable)
        && !(aiEmittedProfiles base ? opencode-web)
        && !((units base) ? opencode-web)
        && !(base.xdg.configFile ? "agent-web/opencode-web/Caddyfile");
      message = "services: the opencode-web preset is off by default (no profile, no unit, no Caddyfile)";
    }
    {
      condition =
        lib.attrNames (units on)
        == ["opencode-web" "opencode-web-proxy"]
        && on.programs.aiSandbox.serviceUnits == {opencode-web = ["opencode-web" "opencode-web-proxy"];};
      message = "services: opencode-web generates exactly its backend unit and its proxy";
    }
    {
      # The preset's unit, spelled out: wrapped in ai-sandbox-run, nono with the service profile, an
      # explicit workdir the profile grants, the strict broker path, loopback bind.
      condition =
        exec on "opencode-web"
        == "${wrap on}${nono on} run --profile opencode-web --workdir ${home}/projects --strict-broker-path --silent -- opencode serve --port 15435 --hostname 127.0.0.1"
        && (units on).opencode-web.Service.WorkingDirectory == "${home}/projects"
        && envOf on "opencode-web"
        == [
          "AI_SANDBOX_RELAX="
          "PATH=/run/wrappers/bin:/etc/profiles/per-user/ai-test/bin:/run/current-system/sw/bin"
          "TMPDIR=%t/agent-web/opencode-web"
        ]
        && (units on).opencode-web.Service.RuntimeDirectory == "agent-web/opencode-web";
      message = "services: the opencode-web unit runs nono through ai-sandbox-run with its profile, workdir and strict broker path";
    }
    {
      # Every sandboxed unit of every service starts through the wrapper with --workdir and
      # --strict-broker-path and empties AI_SANDBOX_RELAX.
      condition = lib.all (n:
        lib.hasPrefix (wrap both) (exec both n)
        && lib.hasInfix " --workdir ${home}/projects " (exec both n)
        && lib.hasInfix " --strict-broker-path " (exec both n)
        && lib.elem "AI_SANDBOX_RELAX=" (envOf both n))
      sandboxed;
      message = "services: every sandboxed unit starts through ai-sandbox-run with --workdir and --strict-broker-path";
    }
    {
      condition =
        exec noIso "opencode-web"
        == "${nono noIso} run --profile opencode-web --workdir ${home}/projects --strict-broker-path --silent -- opencode serve --port 15435 --hostname 127.0.0.1"
        && !(lib.elem "AI_SANDBOX_RELAX=" (envOf noIso "opencode-web"));
      message = "services: with isolation.enable = false the units start nono directly";
    }
    {
      # The proxy: Caddy, not sandboxed, listening on the service's port and forwarding to its
      # backend; ordered against the backend unit, which pulls it in.
      condition = let
        p = (units on).opencode-web-proxy;
        text = caddyfile on "opencode-web";
      in
        exec on "opencode-web-proxy"
        == "${pkgs.caddy}/bin/caddy run --config ${home}/.config/agent-web/opencode-web/Caddyfile --adapter caddyfile"
        && p.Unit.PartOf == ["opencode-web.service"]
        && p.Unit.After == ["opencode-web.service"]
        && (units on).opencode-web.Unit.Wants == ["opencode-web-proxy.service"]
        && lib.hasInfix ":15434 {" text
        && lib.hasInfix "reverse_proxy 127.0.0.1:15435 {" text
        && lib.hasInfix "encode zstd gzip" text
        && lib.hasInfix "flush_interval -1" text;
      message = "services: the opencode-web proxy is an unsandboxed Caddy from its listen port to its backend port, wanted by the backend";
    }
    {
      # The proxy binds loopback by default; the Caddyfile and the unit's Description follow
      # proxy.listenAddress. 0.0.0.0 is every interface: no bind line (Caddy's default).
      condition =
        on.programs.aiSandbox.services.opencode-web.proxy.listenAddress
        == "127.0.0.1"
        && siteHead on == "\tbind 127.0.0.1\n"
        && proxyDescription on == "Compressing loopback proxy for opencode-web"
        && siteHead (listening "0.0.0.0") == ""
        && proxyDescription (listening "0.0.0.0") == "Compressing proxy for opencode-web on every interface"
        && siteHead (listening "192.0.2.10") == "\tbind 192.0.2.10\n"
        && proxyDescription (listening "192.0.2.10") == "Compressing proxy for opencode-web on 192.0.2.10"
        && siteHead (listening "::1") == "\tbind ::1\n"
        && proxyDescription (listening "::1") == "Compressing loopback proxy for opencode-web"
        && siteHead (listening "2001:db8::7") == "\tbind 2001:db8::7\n"
        && lib.all (a:
          aiFailedWith {
            imports = [oc];
            programs.aiSandbox.services.opencode-web.proxy.listenAddress = a;
          }
          == []) ["0.0.0.0" "127.0.0.2" "192.0.2.10" "::1" "::" "2001:db8::7" "1:2:3:4:5:6:7:8" "fe80::"];
      message = "services: the proxy binds proxy.listenAddress (default 127.0.0.1; 0.0.0.0 without a bind line), and its Description says where";
    }
    {
      # Not an address: a host name, an empty value (0.0.0.0 is the one spelling of every
      # interface), brackets, a zone, a port, a malformed IPv4 or IPv6 literal.
      condition = lib.all badListen ["" "localhost" "[::1]" "fe80::1%eth0" "127.0.0.1:80" "127.0.0.1 " "256.0.0.1" "1.2.3" "01.2.3.4" "::1::" ":::" "1:2:3:4:5:6:7:8:9" "12345::" "::g"];
      message = "services: a proxy.listenAddress that is not an IPv4 or IPv6 address must fail the module assertion";
    }
    {
      # The generic service: units as given, the proxy off, the backend named by backendUnit.
      condition = let
        u = units both;
      in
        lib.attrNames u
        == ["opencode-web" "opencode-web-proxy" "svc-daemon" "svc-server"]
        && !(both.xdg.configFile ? "agent-web/svc/Caddyfile")
        && u.svc-server.Unit.After == ["svc-daemon.service"]
        && !(u.svc-server.Unit ? Wants)
        && lib.elem "SVC_PORT=15501" (envOf both "svc-server")
        && lib.hasSuffix " -- ${pkgs.hello}/bin/hello --serve" (exec both "svc-server")
        && lib.hasInfix " run --profile svc " (exec both "svc-server")
        && both.programs.aiSandbox.serviceUnits.svc == ["svc-daemon" "svc-server"];
      message = "services: a generic service gets its units, its profile and no proxy when proxy.enable = false";
    }
    {
      # The service profile: the preset's grants, its own pack only, its backend port.
      condition = let
        p = ps.opencode-web;
      in
        p.extends
        == ["nolabs-ai/opencode"]
        && p.network.listen_port == [15435]
        && lib.elem "$HOME/projects" p.filesystem.allow
        && lib.elem "$HOME/.claude/.credentials.json" p.filesystem.allow_file
        && p.filesystem.read == ["$HOME/.agents/skills"]
        && lib.elem "opencode-web" on.programs.aiSandbox.internal.managedCommands;
      message = "services: the opencode-web profile extends its own pack, grants the project root and binds exactly its backend port";
    }
    {
      # `network.listen_port` only in service profiles.
      condition = let
        all = aiEmittedProfiles both;
      in
        lib.all (n: (all.${n} ? network) == lib.elem n ["opencode-web" "svc"]) (lib.attrNames all)
        && all.svc.network.listen_port == [15501];
      message = "services: only service profiles declare network.listen_port";
    }
    {
      condition = let
        d = aiEmittedProfiles withDelta;
      in
        lib.elem "$HOME/.pack-delta" d.opencode-web.filesystem.allow_file
        && d.opencode-web.environment.set_vars.PACK_DELTA == "1";
      message = "services: packDefaults reach the service profiles of the pack";
    }
    {
      # A service on => `agentWebDirs` (after writeBoundary), creating exactly the enabled
      # services' data dirs at 0700; no services => no entry.
      condition = let
        a = both.home.activation.agentWebDirs;
      in
        a.data
        == ''run install -d -m 0700 "${home}/.svc"''
        && a.after == ["writeBoundary"]
        && on.home.activation.agentWebDirs.data == ""
        && !(base.home.activation ? agentWebDirs);
      message = "services: activation agentWebDirs creates the enabled services' data dirs, and exists iff a service is on";
    }
    {
      condition = aiFailedWith {imports = [oc svcModule];} == [];
      message = "services: two services on distinct ports evaluate (the healthy case of the guards below)";
    }
    {
      condition = aiFailsWith "ai-sandbox: services' listen and backend ports must be pairwise distinct" {
        imports = [oc svcModule];
        programs.aiSandbox.services.svc.listenPort = lib.mkForce 15434;
      };
      message = "services: two services on one port must fail the module assertion";
    }
    {
      condition = aiFailsWith "ai-sandbox: programs.aiSandbox.services require programs.aiSandbox.enable" {
        imports = [oc];
        programs.aiSandbox.enable = false;
      };
      message = "services: a service without programs.aiSandbox.enable must fail the module assertion";
    }
    {
      # A preset is per-leaf defaults: overriding the ports or the proxy package changes the unit,
      # the Caddyfile and the profile, and leaves the rest of the preset in place.
      condition = let
        p = (aiEmittedProfiles overridden).opencode-web;
        text = caddyfile overridden "opencode-web";
      in
        lib.hasSuffix " -- opencode serve --port 16000 --hostname 127.0.0.1" (exec overridden "opencode-web")
        && lib.hasInfix ":16001 {" text
        && lib.hasInfix "reverse_proxy 127.0.0.1:16000 {" text
        && p.network.listen_port == [16000]
        && p.extends == ["nolabs-ai/opencode"]
        && lib.hasPrefix "${fakeCaddy}/bin/caddy run --config " (exec overridden "opencode-web-proxy")
        && lib.hasPrefix "${fakeCaddy}/bin/caddy reload " (units overridden).opencode-web-proxy.Service.ExecReload;
      message = "services: overriding a preset's ports or proxy.package reaches its unit, Caddyfile and profile";
    }
    {
      condition = aiFailsWith "ai-sandbox: programs.aiSandbox.services.opencode-web.backendUnit" {
        imports = [oc];
        programs.aiSandbox.services.opencode-web.backendUnit = "opencode";
      };
      message = "services: a proxied service whose backendUnit names none of its units must fail the module assertion";
    }
    {
      # The service profile is named after the service: a harness command or any emitted harness /
      # variant profile name would be replaced by it.
      condition =
        aiFailsWith "ai-sandbox: service names must not be harness commands or profile names" (bare "pi" 15600)
        && aiFailsWith "ai-sandbox: service names must not be harness commands or profile names" (bare "pi-claude" 15600)
        && aiFailsWith "ai-sandbox: service names must not be harness commands or profile names" {
          imports = [(bare "pi-claude-y" 15600)];
          programs.aiSandbox.variants.pi_y = {
            harness = "pi";
            suffix = "y";
          };
        };
      message = "services: a service named like a harness command, harness profile or variant profile must fail the module assertion";
    }
    {
      condition =
        aiFailsWith "ai-sandbox: services' unit names" {
          imports = [oc (bare "svc2" 15600)];
          programs.aiSandbox.services.svc2.units.opencode-web-proxy = {
            description = "clash";
            exec = ["${pkgs.hello}/bin/hello"];
          };
        }
        && aiFailsWith "ai-sandbox: services' unit names" {
          imports = [(bare "svc3" 15600)];
          programs.aiSandbox.services.svc3 = {
            proxy.enable = lib.mkForce true;
            units.svc3-proxy = {
              description = "clash";
              exec = ["${pkgs.hello}/bin/hello"];
            };
          };
        };
      message = "services: a unit named like another service's unit or a service's own <name>-proxy must fail the module assertion";
    }
    {
      # workdir is WorkingDirectory= and a space-joined ExecStart argument; exec is joined with
      # spaces; dataDirs go into a double-quoted activation line.
      condition =
        aiFailsWith "ai-sandbox: programs.aiSandbox.services.opencode-web.workdir" {
          imports = [oc];
          programs.aiSandbox.services.opencode-web.workdir = "projects";
        }
        && aiFailsWith "ai-sandbox: programs.aiSandbox.services.opencode-web.workdir" {
          imports = [oc];
          programs.aiSandbox.services.opencode-web.workdir = "/tmp/my projects";
        }
        && aiFailsWith "ai-sandbox: programs.aiSandbox.services.opencode-web.units.opencode-web.exec" {
          imports = [oc];
          programs.aiSandbox.services.opencode-web.units.opencode-web.exec = lib.mkForce ["opencode serve"];
        }
        && aiFailsWith "ai-sandbox: programs.aiSandbox.services.opencode-web.dataDirs" {
          imports = [oc];
          programs.aiSandbox.services.opencode-web.dataDirs = [".oc"];
        }
        && aiFailsWith "ai-sandbox: programs.aiSandbox.services.opencode-web.dataDirs" {
          imports = [oc];
          programs.aiSandbox.services.opencode-web.dataDirs = ["/tmp/a\"b"];
        }
        && aiFailedWith {
          imports = [oc];
          programs.aiSandbox.services.opencode-web.dataDirs = ["$HOME/.oc" "/tmp/oc"];
        }
        == [];
      message = "services: a relative or whitespace workdir, a whitespace exec argument and a relative or quote-breaking data dir must fail the module assertion";
    }
  ]
