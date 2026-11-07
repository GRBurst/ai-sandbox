# scripts/packs: `<pack> <version>` lines, `#` comments; the one parser of both routes' pins.
{lib}: text: let
  lines = lib.filter (l: l != "" && !(lib.hasPrefix "#" l)) (map lib.trim (lib.splitString "\n" text));
  fields = l: lib.filter (s: s != "") (lib.splitString " " l);
  wellFormed = l: let
    f = fields l;
  in
    lib.length f
    == 2
    && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*" (lib.elemAt f 0) != null
    && builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" (lib.elemAt f 1) != null;
  good = lib.filter wellFormed lines;
in {
  pinned = map (l: lib.head (fields l)) good; # list, for the `doubled` check
  pins = lib.listToAttrs (map (l: lib.nameValuePair (lib.elemAt (fields l) 0) (lib.elemAt (fields l) 1)) good);
  malformed = lib.filter (l: !(wellFormed l)) lines;
}
