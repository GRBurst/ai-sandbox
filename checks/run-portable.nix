# The ai-sandbox-run suite against the installed portable wrapper. The installer
# puts the wrapper and its helpers into a scratch prefix, once with every layer
# on and once without `pid` (a fixture defaults file, as the Nix check builds
# its two wrappers); then the very same suite text runs against them. A variable
# the preamble template does not assign fails there under `set -u`. Besides:
# shellcheck reads the assembled scripts, and the portable preamble assigns
# exactly the variables the Nix build injects (preamble-vars).
{
  pkgs,
  lib,
  self,
}: let
  inherit (pkgs.callPackage ./ai-sandbox-run/fixture.nix {}) fx fakeNono fakeOpenBin runtimeRoot sockets;
  suite = pkgs.callPackage ./ai-sandbox-run/suite.nix {};
  shipped = builtins.fromJSON (builtins.readFile ../packages/ai-sandbox-run/defaults.json);
  fixtureDefaults = layers:
    pkgs.writeText "defaults.json" (builtins.toJSON {inherit layers runtimeRoot sockets;});
  withPid = fixtureDefaults shipped.layers;
  withoutPid = fixtureDefaults (lib.remove "pid" shipped.layers);
  # the tools the installer resolves: stubs first, then the real ones
  stubs = pkgs.symlinkJoin {
    name = "portable-stubs";
    paths = [fakeNono fakeOpenBin];
  };
  installerPath = lib.makeBinPath [pkgs.bash pkgs.coreutils pkgs.jq pkgs.git pkgs.socat pkgs.util-linux pkgs.bubblewrap];
  # the wrapper as the Nix build assembles it (the stub nono: only the variable
  # names are read from it)
  nixWrapper = import ../packages/ai-sandbox-run/sandbox-run.nix {
    inherit pkgs lib;
    nono = fakeNono;
  };
  runSh = ../packages/ai-sandbox-run/sandbox-run.sh;
in
  suite {
    name = "run-portable";
    W = "$P1/bin/ai-sandbox-run";
    NOPID = "$P2/bin/ai-sandbox-run";
    CHECK = "$P1/libexec/ai-sandbox/ai-sandbox-url-check";
    SHIM = "$P1/libexec/ai-sandbox/shim/xdg-open";
    tokens = shipped.layers ++ ["browser"];
    inherit fx;
    extraInputs = [pkgs.shellcheck pkgs.diffutils];
    pre = ''
      export HOME=$NIX_BUILD_TOP/home
      mkdir -p "$HOME"
      inst() { # inst PREFIX DEFAULTS
        env -i HOME="$HOME" PATH=${stubs}/bin:${installerPath} PREFIX="$1" \
          XDG_DATA_HOME="$1/data" AI_SANDBOX_DEFAULTS="$2" \
          bash ${self}/scripts/install.sh install >"$1.log" 2>&1 || { cat "$1.log" >&2; exit 1; }
      }
      P1=$NIX_BUILD_TOP/prefix-all
      P2=$NIX_BUILD_TOP/prefix-nopid
      inst "$P1" ${withPid}
      inst "$P2" ${withoutPid}
      # the build sandbox has no /usr/bin/env: point the shebangs at this bash
      patchShebangs "$P1" "$P2" >/dev/null
      for f in "$P1/bin/ai-sandbox-run" "$P1/libexec/ai-sandbox/ai-sandbox-url-relay" \
        "$P1/libexec/ai-sandbox/ai-sandbox-url-check" "$P1/libexec/ai-sandbox/shim/xdg-open"; do
        shellcheck -s bash "$f" || { echo "FAIL: shellcheck: the installed $f" >&2; exit 1; }
      done
      # preamble-vars: the names assigned before the first line of sandbox-run.sh
      vars() {
        local first n
        first=$(head -n 1 ${runSh})
        n=$(grep -nxF -m 1 -- "$first" "$1" | cut -d: -f1)
        head -n $((n - 1)) "$1" | grep -oE '^[a-z_]+=' | sort -u
      }
      vars ${nixWrapper}/bin/ai-sandbox-run >"$NIX_BUILD_TOP/vars.nix"
      vars "$P1/bin/ai-sandbox-run" >"$NIX_BUILD_TOP/vars.portable"
      [ -s "$NIX_BUILD_TOP/vars.nix" ] || { echo "FAIL: preamble-vars: no variables found in the Nix wrapper" >&2; exit 1; }
      diff -u "$NIX_BUILD_TOP/vars.nix" "$NIX_BUILD_TOP/vars.portable" ||
        { echo "FAIL: preamble-vars: the Nix preamble (-) and the portable preamble (+) assign different variables" >&2; exit 1; }
    '';
  }
