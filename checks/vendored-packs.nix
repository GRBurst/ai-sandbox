# The registry profiles vendored under `modules/home-manager/vendor/` (the source of the
# ai-sandbox bases, modules/home-manager/bases.nix) are the pack's own `policy.json`, byte for
# byte, at the version `scripts/packs` pins: the file's sha256 is the one recorded beside it
# (the registry digest of that version), and the recorded version is the pin. A pin bump
# without a re-vendor, or an edited copy, fails here. Read at evaluation time.
{
  pkgs,
  lib,
  self,
}: let
  bases = import ../modules/home-manager/bases.nix {inherit lib;};
  pins = (import ../modules/home-manager/packs.nix {inherit lib;} (builtins.readFile "${self}/scripts/packs")).pins;

  problems = pack: let
    b = bases.${pack};
    hash = builtins.hashFile "sha256" b.file;
  in
    lib.optional (hash != b.sha256) "${pack}: the vendored ${baseNameOf b.file} has sha256 ${hash}, not ${b.sha256} (the pack's policy.json at ${b.version}); re-vendor it byte for byte"
    ++ lib.optional ((pins.${pack} or null) != b.version) "${pack}: vendored at ${b.version}, but scripts/packs pins ${pins.${pack} or "nothing"}; re-vendor the pack's policy.json at the pin and record its sha256";

  all =
    lib.optional (bases == {}) "modules/home-manager/bases.nix re-bases no pack"
    ++ lib.concatMap problems (lib.attrNames bases);
in
  pkgs.runCommand "vendored-packs" {} (
    if all == []
    then "touch $out"
    else "printf '%s\\n' ${lib.escapeShellArg "vendored-packs: ${lib.concatStringsSep "; " all}"} >&2; exit 1"
  )
