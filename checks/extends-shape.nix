# The shape every profile of the non-Nix path keeps (isolation invariant E): one `extends`
# entry. A shipped profile (`profiles/`) extends a registry pack (`nolabs-ai/...`); an example
# (`examples/without-nix/`) extends a shipped profile, so every ancestry holds exactly one pack.
# A profile's `meta.name` is its file name. Read at evaluation time (the sources are in the
# store already).
{
  pkgs,
  lib,
  self,
}: let
  load = dir: let
    names = lib.filter (lib.hasSuffix ".json") (lib.attrNames (builtins.readDir "${self}/${dir}"));
  in
    map (f: {
      inherit dir;
      name = lib.removeSuffix ".json" f;
      p = builtins.fromJSON (builtins.readFile "${self}/${dir}/${f}");
    })
    names;

  shipped = load "profiles";
  examples = load "examples/without-nix";
  shippedNames = map (x: x.name) shipped;

  where = x: "${x.dir}/${x.name}.json";
  problems = x: let
    ext = x.p.extends or [];
    parent = lib.head ext;
  in
    lib.optional (lib.length ext != 1) "${where x}: extends must hold exactly one entry, has ${toString (lib.length ext)}"
    ++ lib.optional (lib.length ext == 1 && x.dir == "profiles" && !(lib.hasPrefix "nolabs-ai/" parent)) "${where x}: a shipped profile must extend a registry pack (nolabs-ai/...), extends ${parent}"
    ++ lib.optional (lib.length ext == 1 && x.dir != "profiles" && !(lib.elem parent shippedNames)) "${where x}: an example must extend a shipped profile (${toString shippedNames}), extends ${parent}"
    ++ lib.optional ((x.p.meta.name or null) != x.name) "${where x}: meta.name must be ${x.name}";

  all =
    lib.optional (shipped == []) "no shipped profile in profiles/"
    ++ lib.optional (examples == []) "no example in examples/without-nix/"
    ++ lib.concatMap problems (shipped ++ examples);
in
  pkgs.runCommand "extends-shape" {} (
    if all == []
    then "touch $out"
    else "printf '%s\\n' ${lib.escapeShellArg "extends-shape: ${lib.concatStringsSep "; " all}"} >&2; exit 1"
  )
