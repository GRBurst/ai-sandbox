# Your existing configuration, unchanged: the sandbox module is added next to
# it in flake.nix and touches none of this.
{pkgs, ...}: {
  home = {
    username = "tester";
    homeDirectory = "/home/tester";
    stateVersion = "26.05";
    packages = [pkgs.ripgrep pkgs.jq];
  };
  programs.home-manager.enable = true;
  programs.fzf.enable = true;
}
