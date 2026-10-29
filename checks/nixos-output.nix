# The flake's `nixosModules.default` itself (the module checks import the file by path):
# evaluated with a stub for the one option it sets.
{
  pkgs,
  lib,
  self,
  home-manager,
}: let
  inherit (import ./module/lib.nix {inherit pkgs lib home-manager;}) mkAssertionCheck;
  stub = {options.boot.kernel.sysctl = lib.mkOption {type = lib.types.attrsOf lib.types.anything;};};
  eval = modules: (lib.evalModules {modules = modules ++ [stub];}).config;
  module = self.nixosModules.default;
  on = eval [module {programs.aiSandbox.enable = true;}];
  off = eval [module];
  twice = eval [module module {programs.aiSandbox.enable = true;}];
in
  mkAssertionCheck "nixos-output" [
    {
      condition = on.boot.kernel.sysctl."dev.tty.legacy_tiocsti" == 0;
      message = "nixosModules.default: enabling the sandbox must pin dev.tty.legacy_tiocsti to 0";
    }
    {
      condition = off.boot.kernel.sysctl == {} && !off.programs.aiSandbox.enable;
      message = "nixosModules.default: off by default, and then sets no sysctl";
    }
    {
      condition = twice.boot.kernel.sysctl."dev.tty.legacy_tiocsti" == 0;
      message = "nixosModules.default: importing it twice evaluates once (module key)";
    }
  ]
