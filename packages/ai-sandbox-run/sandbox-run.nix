# The isolation wrapper. Own file so checks/ai-sandbox-run can build it
# against fixture paths; the flake and the module build it with the defaults
# of defaults.json (the installer reads the same file).
{
  pkgs,
  lib,
  nono,
  defaults ? builtins.fromJSON (builtins.readFile ./defaults.json),
  layers ? defaults.layers,
  runtimeRoot ? defaults.runtimeRoot,
  sockets ? defaults.sockets,
  xdgOpen ? "${pkgs.xdg-utils}/bin/xdg-open",
}: let
  allLayers = import ./sandbox-layers.nix;
  arr = xs: "(${lib.escapeShellArgs xs})";

  urlCheck = pkgs.writeShellApplication {
    name = "ai-sandbox-url-check";
    runtimeInputs = [pkgs.jq];
    text = builtins.readFile ./sandbox-url-check.sh;
  };

  urlRelay = pkgs.writeShellApplication {
    name = "ai-sandbox-url-relay";
    runtimeInputs = [urlCheck pkgs.util-linux];
    text =
      ''
        xdg_open=${lib.escapeShellArg xdgOpen}
      ''
      + builtins.readFile ./sandbox-url-relay.sh;
  };

  shim = pkgs.writeShellApplication {
    name = "xdg-open";
    runtimeInputs = [pkgs.socat];
    text = builtins.readFile ./sandbox-xdg-open.sh;
  };
in
  pkgs.writeShellApplication {
    name = "ai-sandbox-run";
    # Deliberately empty: writeShellApplication PREPENDS runtimeInputs to PATH,
    # and this script execs the agent with its environment, so a store PATH
    # would leak into the agent. Every tool below is an absolute store path instead.
    runtimeInputs = [];
    text =
      ''
        all_layers=${arr allLayers}
        default_layers=${arr layers}
        docker_sockets=${arr sockets.docker}
        system_sockets=${arr sockets.system}
        runtime_root=${lib.escapeShellArg runtimeRoot}
        shim_bin=${shim}/bin
        url_relay=${urlRelay}/bin/ai-sandbox-url-relay
        bwrap=${pkgs.bubblewrap}/bin/bwrap
        socat=${pkgs.socat}/bin/socat
        jq=${pkgs.jq}/bin/jq
        git=${pkgs.git}/bin/git
        nono_bin=${nono}/bin/nono
        coreutils=${pkgs.coreutils}/bin
      ''
      + builtins.readFile ./sandbox-run.sh;
    passthru = {
      inherit allLayers urlCheck urlRelay shim;
      tokens = allLayers ++ ["browser"];
    };
  }
