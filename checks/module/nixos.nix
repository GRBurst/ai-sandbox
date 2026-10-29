# The NixOS module of the sandbox (modules/nixos/default.nix): evaluated alone with a
# stub for the one option it sets, so no host is involved. Wired by ./default.nix as
# ai-sandbox-nixos.
{
  lib,
  helpers,
}: let
  inherit (helpers) mkAssertionCheck;
  module = helpers.nixosModule;
  eval = extra:
    (lib.evalModules {
      modules = [
        module
        {options.boot.kernel.sysctl = lib.mkOption {type = lib.types.attrsOf lib.types.anything;};}
        extra
      ];
    })
    .config;
  on = eval {programs.aiSandbox.enable = true;};
  off = eval {};
in
  mkAssertionCheck "ai-sandbox-nixos" [
    {
      condition = on.boot.kernel.sysctl."dev.tty.legacy_tiocsti" == 0;
      message = "nixos: enabling the sandbox must pin dev.tty.legacy_tiocsti to 0 (TIOCSTI injection stays impossible)";
    }
    {
      condition = off.boot.kernel.sysctl == {} && !off.programs.aiSandbox.enable;
      message = "nixos: the sandbox is off by default and then sets no sysctl at all";
    }
  ]
