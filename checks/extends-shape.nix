# The shape every profile of the non-Nix path keeps (isolation invariant E): one `extends`
# entry. A shipped profile (`profiles/`) extends a registry pack (`nolabs-ai/...`) or a
# shipped ai-sandbox base (modules/home-manager/bases.nix: the pack's own profile minus its
# grants on the harness's config), and a base extends nono's built-in `default`, as the pack
# does; an example (`examples/without-nix/`) extends a shipped profile, so every ancestry
# holds exactly one pack's profile. A profile's `meta.name` is its file name. `scripts/packs`
# pins exactly the packs the shipped profiles extend or are based on (`<pack> <version>`
# lines; the installer pulls a missing one at that version). Read at evaluation time (the
# sources are in the store already).
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

  # base name -> the pack it is made from
  bases = import ../modules/home-manager/bases.nix {inherit lib;};
  basePack = lib.mapAttrs' (pack: b: lib.nameValuePair b.name pack) bases;
  isBase = n: basePack ? ${n};

  where = x: "${x.dir}/${x.name}.json";
  problems = x: let
    ext = x.p.extends or [];
    parent = lib.head ext;
    one = lib.length ext == 1;
  in
    lib.optional (!one) "${where x}: extends must hold exactly one entry, has ${toString (lib.length ext)}"
    ++ lib.optional (one && x.dir == "profiles" && isBase x.name && parent != "default") "${where x}: an ai-sandbox base must extend default, extends ${parent}"
    ++ lib.optional (one && x.dir == "profiles" && !(isBase x.name) && !(lib.hasPrefix "nolabs-ai/" parent) && !(isBase parent && lib.elem parent shippedNames)) "${where x}: a shipped profile must extend a registry pack (nolabs-ai/...) or a shipped ai-sandbox base (${toString (lib.attrNames basePack)}), extends ${parent}"
    ++ lib.optional (one && x.dir != "profiles" && !(lib.elem parent shippedNames)) "${where x}: an example must extend a shipped profile (${toString shippedNames}), extends ${parent}"
    ++ lib.optional ((x.p.meta.name or null) != x.name) "${where x}: meta.name must be ${x.name}";

  # scripts/packs, parsed by the parser the module shares (modules/home-manager/packs.nix)
  packs = import ../modules/home-manager/packs.nix {inherit lib;} (builtins.readFile "${self}/scripts/packs");
  pinned = packs.pinned;
  # the pack of each shipped leaf: the one it extends, or the one its base is made from
  extended = lib.unique (map (x: let
    parent = lib.head x.p.extends;
  in
    basePack.${parent} or parent) (lib.filter (x: lib.length (x.p.extends or []) == 1 && !(isBase x.name)) shipped));
  malformed = packs.malformed;
  unpinned = lib.subtractLists pinned extended;
  stale = lib.subtractLists extended pinned;
  doubled = lib.filter (p: lib.count (q: q == p) pinned > 1) (lib.unique pinned);

  all =
    lib.optional (shipped == []) "no shipped profile in profiles/"
    ++ lib.optional (examples == []) "no example in examples/without-nix/"
    ++ lib.concatMap problems (shipped ++ examples)
    ++ lib.optional (malformed != []) "scripts/packs: lines that are not `<namespace>/<pack> <major>.<minor>.<patch>`: ${lib.concatStringsSep ", " malformed}"
    ++ lib.optional (unpinned != []) "scripts/packs pins no version of ${toString unpinned}, which a shipped profile extends or is based on (the installer pulls the pinned version)"
    ++ lib.optional (stale != []) "scripts/packs pins ${toString stale}, which no shipped profile extends or is based on"
    ++ lib.optional (doubled != []) "scripts/packs pins ${toString doubled} more than once";
in
  pkgs.runCommand "extends-shape" {} (
    if all == []
    then "touch $out"
    else "printf '%s\\n' ${lib.escapeShellArg "extends-shape: ${lib.concatStringsSep "; " all}"} >&2; exit 1"
  )
