# The shape every profile of the non-Nix path keeps (isolation invariant E): one `extends`
# entry. A shipped profile (`profiles/`) extends a registry pack (`nolabs-ai/...`); an example
# (`examples/without-nix/`) extends a shipped profile, so every ancestry holds exactly one pack.
# A profile's `meta.name` is its file name. `scripts/packs` pins exactly the packs the shipped
# profiles extend (`<pack> <version>` lines; the installer pulls a missing one at that
# version). Read at evaluation time (the sources are in the store already).
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

  # scripts/packs: `<pack> <version>` lines, `#` comment lines
  packLines = lib.filter (l: l != "" && !(lib.hasPrefix "#" l)) (map lib.trim (lib.splitString "\n" (builtins.readFile "${self}/scripts/packs")));
  fields = l: lib.filter (s: s != "") (lib.splitString " " l);
  wellFormed = l: let
    f = fields l;
  in
    lib.length f
    == 2
    && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*" (lib.elemAt f 0) != null
    && builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" (lib.elemAt f 1) != null;
  pinned = map (l: lib.head (fields l)) (lib.filter wellFormed packLines);
  extended = lib.unique (map (x: lib.head x.p.extends) (lib.filter (x: lib.length (x.p.extends or []) == 1) shipped));
  malformed = lib.filter (l: !(wellFormed l)) packLines;
  unpinned = lib.subtractLists pinned extended;
  stale = lib.subtractLists extended pinned;
  doubled = lib.filter (p: lib.count (q: q == p) pinned > 1) (lib.unique pinned);

  all =
    lib.optional (shipped == []) "no shipped profile in profiles/"
    ++ lib.optional (examples == []) "no example in examples/without-nix/"
    ++ lib.concatMap problems (shipped ++ examples)
    ++ lib.optional (malformed != []) "scripts/packs: lines that are not `<namespace>/<pack> <major>.<minor>.<patch>`: ${lib.concatStringsSep ", " malformed}"
    ++ lib.optional (unpinned != []) "scripts/packs pins no version of ${toString unpinned}, which a shipped profile extends (the installer pulls the pinned version)"
    ++ lib.optional (stale != []) "scripts/packs pins ${toString stale}, which no shipped profile extends"
    ++ lib.optional (doubled != []) "scripts/packs pins ${toString doubled} more than once";
in
  pkgs.runCommand "extends-shape" {} (
    if all == []
    then "touch $out"
    else "printf '%s\\n' ${lib.escapeShellArg "extends-shape: ${lib.concatStringsSep "; " all}"} >&2; exit 1"
  )
