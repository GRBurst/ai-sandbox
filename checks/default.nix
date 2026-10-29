{
  pkgs,
  lib,
  self,
  home-manager,
  render,
}: let
  # Disjoint union of check sets: a duplicate check name is an evaluation error.
  union = lib.foldl' (acc: s: let
    dup = lib.intersectLists (lib.attrNames acc) (lib.attrNames s);
  in
    if dup == []
    then acc // s
    else throw "checks: duplicate check names: ${toString dup}") {};

  # One Home Manager evaluation, shared by the option-table check.
  hm = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      self.homeModules.default
      {
        home = {
          username = "tester";
          homeDirectory = "/home/tester";
          stateVersion = "26.05";
        };
      }
    ];
  };
  all = union [
    {
      # Every `.nix` file in the tree is Alejandra-formatted.
      formatting = pkgs.runCommand "formatting" {nativeBuildInputs = [pkgs.alejandra];} ''
        cd ${self}
        alejandra --check . || {
          echo "formatting: run alejandra on the files above" >&2
          exit 1
        }
        touch $out
      '';

      # Generic personal-data scan of the source, self-tested on fixtures.
      leaks = import ./leaks {inherit pkgs self;};

      # Every leaf option under programs.aiSandbox is named in the README table.
      readme-options = import ./readme-options.nix {
        inherit pkgs lib self;
        inherit (hm) options;
      };

      # The README sections, first-run words, Ports rows and check list.
      readme-sections = import ./readme-sections.nix {
        inherit pkgs lib self;
        inherit (hm) config;
        checkNames = lib.attrNames all;
      };
    }
    # The Home Manager and NixOS modules against fixture users.
    (import ./module {inherit pkgs lib home-manager;})
    {
      # The wrapper builds real isolations in the Nix build sandbox (bubblewrap in a user namespace).
      ai-sandbox-run = pkgs.callPackage ./ai-sandbox-run {};
    }
    {
      # Every tracked `*.sh` is checked or excluded by name; the checked ones are clean.
      shellcheck = import ./shellcheck.nix {inherit pkgs lib self;};

      # The CI workflow is valid.
      actionlint = import ./actionlint.nix {inherit pkgs self;};

      # The suite of the Nix wrapper, against the installed portable wrapper.
      run-portable = import ./run-portable.nix {inherit pkgs lib self;};

      # The installer without Nix: dependencies, put, manifest, uninstall.
      install-sh = import ./install-sh {inherit pkgs lib self render;};

      # The README dependency table and scripts/deps list the same tools.
      readme-deps = import ./readme-deps.nix {inherit pkgs lib self;};

      # Every documentation path a tracked file names exists.
      doc-refs = import ./doc-refs.nix {inherit pkgs self;};

      # The modules and the wrapper name no host coupling; no module reads a rendered file.
      boundary = import ./boundary.nix {inherit pkgs lib home-manager self;};
    }
    {
      # The flake's own nixosModules.default evaluates and pins the kernel setting.
      nixos-output = import ./nixos-output.nix {inherit pkgs lib self home-manager;};
    }
    # The committed non-Nix artifacts against the render fixtures' output.
    (import ./render.nix {inherit pkgs lib self render;})
    {
      # shell/variant.sh prints the Nix alias strings byte for byte, in bash and zsh.
      variant-sh = import ./variant-sh.nix {inherit pkgs lib self render home-manager;};

      # Every shipped and example profile has one `extends`: a pack, or a shipped profile.
      extends-shape = import ./extends-shape.nix {inherit pkgs lib self;};

      # The README path: the example flake with the module added evaluates, offline.
      existing-flake-example = import ./existing-flake.nix {inherit pkgs lib self home-manager;};
    }
  ];
in
  all
