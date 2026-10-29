# ai-sandbox-run builds real isolations in the Nix build sandbox (bubblewrap in
# an unprivileged user namespace; spec F7, A3) against fixture sockets under
# the build's private /tmp, a fake nono and a fake opener. Design:
# docs/specs/2026-09-26-sandbox-namespace-isolation-design.md.
{
  lib,
  pkgs,
  callPackage,
}: let
  inherit (callPackage ./fixture.nix {}) fx fakeNono fakeOpen runtimeRoot sockets;
  all = import ../../packages/ai-sandbox-run/sandbox-layers.nix;
  mk = layers:
    import ../../packages/ai-sandbox-run/sandbox-run.nix {
      inherit pkgs lib layers;
      nono = fakeNono;
      inherit runtimeRoot sockets;
      xdgOpen = "${fakeOpen}";
    };
  run = mk all;
  noPid = mk (lib.remove "pid" all);
  suite = callPackage ./suite.nix {};
in
  suite {
    name = "ai-sandbox-run";
    W = "${run}/bin/ai-sandbox-run";
    NOPID = "${noPid}/bin/ai-sandbox-run";
    CHECK = "${run.urlCheck}/bin/ai-sandbox-url-check";
    SHIM = "${run.shim}/bin/xdg-open";
    inherit fx;
    inherit (run) tokens;
  }
