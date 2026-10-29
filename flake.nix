{
  description = "AI coding-agent sandbox (nono profiles, harness wrappers); works without Nix, first-class Nix support as Home Manager and NixOS modules";

  inputs = {
    # Pinned revs for the checks; consumers `follows` their own anyway.
    nixpkgs.url = "github:NixOS/nixpkgs/31ecbaca1bdefa45dffc409f0250bd8039ea0010";
    home-manager = {
      url = "github:nix-community/home-manager/1e3ebeb683d055d1675d3f64e6d2b186cb2ee504";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forSystems = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    renderOf = pkgs:
      import ./render {
        inherit pkgs self home-manager;
        inherit (nixpkgs) lib;
      };
  in {
    homeModules.default = import ./modules/home-manager;
    nixosModules.default = import ./modules/nixos;

    packages = forSystems (_: pkgs: {
      ai-sandbox-run = import ./packages/ai-sandbox-run/sandbox-run.nix {
        inherit pkgs;
        inherit (nixpkgs) lib;
        nono = pkgs.nono;
      };
    });

    # The render tree, exposed so it can be built and inspected on its own.
    legacyPackages = forSystems (_: pkgs: {render-tree = (renderOf pkgs).tree;});

    # `nix run .#render` writes the generated non-Nix files into the checkout.
    apps = forSystems (_: pkgs: {
      render = {
        type = "app";
        program = nixpkgs.lib.getExe (renderOf pkgs).app;
      };
    });

    formatter = forSystems (_: pkgs: pkgs.alejandra);

    checks = forSystems (_: pkgs:
      import ./checks {
        inherit pkgs self home-manager;
        inherit (nixpkgs) lib;
        render = renderOf pkgs;
      });
  };
}
