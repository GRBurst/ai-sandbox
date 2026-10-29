# The README's "Without Nix" dependency table and `scripts/deps` cannot drift:
# the (binary, package, when) triples of the table rows are exactly the
# triples of the non-comment lines of the file. The table is
# `| binary | package | needed when | minimum |`; the first three cells are
# compared, backticks and blanks ignored, the minimum is prose.
{
  pkgs,
  lib,
  self,
}: let
  whens = ["always" "isolation" "services" "optional"];

  # scripts/deps: whitespace-separated triples, `#` comment lines
  depLines = lib.filter (l: l != "" && !(lib.hasPrefix "#" l)) (map lib.trim (lib.splitString "\n" (builtins.readFile "${self}/scripts/deps")));
  fields = l: lib.filter (s: s != "") (lib.splitString " " l);
  malformedDeps = lib.filter (l: let f = fields l; in lib.length f != 3 || !(lib.elem (lib.elemAt f 2) whens)) depLines;
  fromFile = map (l: lib.concatStringsSep " " (fields l)) depLines;

  # README: the lines from `## Without Nix` up to the next level-2 heading;
  # every table line after the header and the separator is a data row
  lines = lib.splitString "\n" (builtins.readFile "${self}/README.md");
  from = lib.drop (lib.lists.findFirstIndex (l: l == "## Without Nix") (lib.length lines) lines + 1) lines;
  section = lib.take (lib.lists.findFirstIndex (lib.hasPrefix "## ") (lib.length from) from) from;
  rows = lib.drop 2 (lib.filter (lib.hasPrefix "| ") section);
  cell = row: i: lib.replaceStrings ["`"] [""] (lib.trim (lib.elemAt (lib.splitString "|" row) i));
  fromReadme = map (r: lib.concatStringsSep " " [(cell r 1) (cell r 2) (cell r 3)]) rows;

  missing = lib.subtractLists fromReadme fromFile;
  unknown = lib.subtractLists fromFile fromReadme;
  problems =
    lib.optional (section == []) "README.md has no `## Without Nix` section"
    ++ lib.optional (malformedDeps != []) "scripts/deps: lines that are not `<binary> <package> <when>` with when in ${toString whens}: ${toString malformedDeps}"
    ++ lib.optional (missing != []) "in scripts/deps but not in the README table: ${lib.concatStringsSep "; " missing}"
    ++ lib.optional (unknown != []) "in the README table but not in scripts/deps: ${lib.concatStringsSep "; " unknown}";
in
  pkgs.runCommand "readme-deps" {} (
    if problems == []
    then "touch $out"
    else "printf '%s\\n' ${lib.escapeShellArg "readme-deps: ${lib.concatStringsSep " | " problems}"} >&2; exit 1"
  )
