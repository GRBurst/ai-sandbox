# The README's primary path composes: `examples/existing-flake` evaluated offline, with this
# flake as its `ai-sandbox` input and this flake's nixpkgs and home-manager as the consumer's
# (what `follows` resolves to).
#
# - the input URL, both `follows` and the example's lock-free inputs: `nixpkgs`, `home-manager`
#   and `ai-sandbox` only (no other layer is pulled in), and this flake's own inputs the same
#   two besides itself: the sandbox imports nothing else;
# - `homeConfigurations` is exactly [tester], the activation package evaluates, the sandbox is
#   on, and the opencode CLI of `harnesses.opencode.package` is installed once;
# - a second import of `homeModules.default` evaluates to the same result (module key dedup).
{
  pkgs,
  lib,
  self,
  home-manager,
}: let
  inherit (import ./module/lib.nix {inherit pkgs lib home-manager;}) mkAssertionCheck;

  dir = "${self}/examples/existing-flake";
  present = builtins.pathExists "${dir}/flake.nix";
  # absent: the empty flake, so the first message names the missing file
  flake =
    if present
    then import "${dir}/flake.nix"
    else {};
  outputs =
    if present
    then
      flake.outputs {
        self = outputs // {outPath = dir;};
        ai-sandbox = self;
        inherit (self.inputs) nixpkgs home-manager;
      }
    else {};
  ins = flake.inputs or {};
  hcs = outputs.homeConfigurations or {};
  hc = hcs.tester or null;
  ok = present && hc != null;
  c = hc.config;
  twice = hc.extendModules {modules = [self.homeModules.default];};

  names = lib.optionals ok (map lib.getName c.home.packages);
  count = n: lib.length (lib.filter (x: x == n) names);
  sorted = lib.sort (a: b: a < b);
  # a condition that reads the configuration is only evaluated when there is one
  needs = cond: ok && cond;
in
  mkAssertionCheck "existing-flake-example" [
    {
      condition = present;
      message = "examples/existing-flake/flake.nix does not exist";
    }
    {
      condition = (ins.ai-sandbox.url or null) == "github:GRBurst/ai-sandbox";
      message = "inputs.ai-sandbox.url is not github:GRBurst/ai-sandbox";
    }
    {
      condition = (ins.ai-sandbox.inputs.nixpkgs.follows or null) == "nixpkgs";
      message = "inputs.ai-sandbox.inputs.nixpkgs does not follow nixpkgs";
    }
    {
      condition = (ins.ai-sandbox.inputs.home-manager.follows or null) == "home-manager";
      message = "inputs.ai-sandbox.inputs.home-manager does not follow home-manager";
    }
    {
      condition = (ins.home-manager.inputs.nixpkgs.follows or null) == "nixpkgs";
      message = "inputs.home-manager.inputs.nixpkgs does not follow nixpkgs";
    }
    {
      condition = sorted (lib.attrNames ins) == ["ai-sandbox" "home-manager" "nixpkgs"];
      message = "the example's inputs are not exactly nixpkgs, home-manager and ai-sandbox: ${toString (lib.attrNames ins)}";
    }
    {
      condition = sorted (lib.attrNames self.inputs) == ["home-manager" "nixpkgs"];
      message = "the flake's own inputs are not exactly nixpkgs and home-manager: ${toString (lib.attrNames self.inputs)}";
    }
    {
      condition = lib.attrNames hcs == ["tester"];
      message = "homeConfigurations is not exactly [tester]";
    }
    {
      condition = needs (builtins.isString c.home.activationPackage.drvPath);
      message = "the activation package does not evaluate";
    }
    {
      condition = needs c.programs.aiSandbox.enable;
      message = "programs.aiSandbox.enable is off";
    }
    {
      condition = count "opencode" == 1;
      message = "opencode is not installed exactly once: ${toString (count "opencode")}";
    }
    {
      condition = lib.elem "ripgrep" names;
      message = "the user's own packages are gone";
    }
    {
      condition = needs (twice.config.home.activationPackage.drvPath == c.home.activationPackage.drvPath);
      message = "importing homeModules.default a second time changes the result (module key dedup)";
    }
  ]
