{
  description = "An existing Home Manager flake with the ai-sandbox module added";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Added: the sandbox, on your nixpkgs and home-manager.
    ai-sandbox = {
      url = "github:GRBurst/ai-sandbox";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = {
    nixpkgs,
    home-manager,
    ai-sandbox,
    ...
  }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    homeConfigurations.tester = home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        ./home.nix
        # Added: the module, and the sandbox switched on with its defaults:
        # the agy, claude, opencode and pi harnesses, their `_nono` twins and
        # the GPU twins claude_gpu and opencode_gpu.
        ai-sandbox.homeModules.default
        {
          programs.aiSandbox = {
            enable = true;
            # Install the opencode CLI next to its profile (null installs nothing).
            harnesses.opencode.package = pkgs.opencode;
          };
        }
      ];
    };
  };
}
