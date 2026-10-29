# The render checks: the committed non-Nix artifacts against the render fixtures' output
# (`render.tree`, built by ../render/default.nix, which also checks that no store path and
# no unknown placeholder reaches an artifact). `diff -ru` names a differing, a missing and
# an extra file alike.
{
  pkgs,
  lib,
  self,
  render,
}: let
  mk = name: dirs:
    pkgs.runCommand name {} ''
      for d in ${lib.escapeShellArgs dirs}; do
        diff -ru ${render.tree}/$d ${self}/$d || {
          echo "${name}: $d differs from the Nix output; run nix run .#render" >&2
          exit 1
        }
      done
      touch $out
    '';
in {
  render-profiles = mk "render-profiles" ["profiles"];
  render-aliases = mk "render-aliases" ["shell/aliases.d" "shell/aliases-nono.d"];
  render-units = mk "render-units" ["services" "services-nono"];
  render-sysctl = mk "render-sysctl" ["sysctl"];
  render-install = mk "render-install" ["install"];
}
