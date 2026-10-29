# The README's option table and the option tree cannot drift: every leaf
# option under `programs.aiSandbox` is named in the first cell of a row of
# the `## Options` table, and every name there is a leaf option. Names are
# backticked and relative to `programs.aiSandbox`; one row may name several.
#
# Leaves, to any depth: an internal option is dropped; a `submodule` option
# stands for its fields (`<option>.<field>`); an `attrsOf`/`lazyAttrsOf` of a
# submodule stands for the fields of one entry (`<option>.<name>.<field>`);
# any other option is a leaf, unless its type nests sub-options this check does not follow
# (a `listOf`/`nullOr` of a submodule, an `attrsOf` of an `attrsOf` of a submodule, ...):
# that is an error, not a silent leaf. The sub-options are taken at the option's own
# location, as the manual does: there a submodule's `_module.args` is internal.
{
  pkgs,
  lib,
  self,
  options,
}: let
  # Leaf names below `prefix` of an option tree (an attrset of options and nested sets).
  leaves = prefix: tree:
    lib.concatLists (lib.mapAttrsToList (
        n: v: let
          p = prefix ++ [n];
        in
          if lib.isOption v
          then optionLeaves p v
          else if lib.isAttrs v
          then leaves p v
          else []
      )
      tree);
  isSubmodule = t: t.name == "submodule";
  optionLeaves = p: o:
    if o.internal or false
    then []
    else if isSubmodule o.type
    then leaves p (o.type.getSubOptions o.loc)
    else if lib.elem o.type.name ["attrsOf" "lazyAttrsOf"] && isSubmodule o.type.nestedTypes.elemType
    then leaves (p ++ ["<name>"]) (o.type.nestedTypes.elemType.getSubOptions (o.loc ++ ["<name>"]))
    else if lib.attrNames (o.type.getSubOptions o.loc) != []
    then throw "readme-options: ${lib.concatStringsSep "." p} has type ${o.type.description} with sub-options this check does not follow; handle that nesting in checks/readme-options.nix"
    else [(lib.concatStringsSep "." p)];
  want = leaves [] options.programs.aiSandbox;

  lines = lib.splitString "\n" (builtins.readFile "${self}/README.md");
  # the lines from `## Options` up to the next level-2 heading
  from = lib.drop (lib.lists.findFirstIndex (l: l == "## Options") (lib.length lines) lines + 1) lines;
  section = lib.take (lib.lists.findFirstIndex (lib.hasPrefix "## ") (lib.length from) from) from;
  rows = lib.filter (lib.hasPrefix "| ") section;
  firstCell = row: lib.elemAt (lib.splitString "|" row) 1;
  # the odd pieces of a split on "`" are the backticked names
  ticked = s: let
    parts = lib.splitString "`" s;
  in
    map (i: lib.elemAt parts i) (lib.filter (i: lib.mod i 2 == 1) (lib.range 0 (lib.length parts - 1)));
  named = lib.concatMap (r: ticked (firstCell r)) rows;

  missing = lib.subtractLists named want;
  unknown = lib.subtractLists want named;
  problems =
    lib.optional (section == []) "README.md has no `## Options` section"
    ++ lib.optional (missing != []) "options missing from the README table: ${toString missing}"
    ++ lib.optional (unknown != []) "README table names that are no leaf option: ${toString unknown}";
in
  pkgs.runCommand "readme-options" {} (
    if problems == []
    then "touch $out"
    else "printf '%s\\n' ${lib.escapeShellArg "readme-options: ${lib.concatStringsSep "; " problems}"} >&2; exit 1"
  )
