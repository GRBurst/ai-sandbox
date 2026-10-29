# The README as a user's first page: the sections exist, the words a stranger needs are in
# them, the Ports table covers every preset service, and the hand-kept check list of
# `## Outputs` is the flake's check set.
#
# - headings: `## Install with Nix`, `## Without Nix`, `## Options`, `## Ports`,
#   `## Isolation`, `## Checks`;
# - "first-class Nix support" is in the README and in the flake's description;
# - per section, the words in `mentions` (some derived from the module: the harnesses on
#   by default, the preset services, the isolation layers) occur in it;
# - Ports: every preset service has a row (a line starting `| `) that names it in backticks
#   and both of its ports as whole numbers, the ports taken from the evaluated module;
# - Outputs: the backticked names of the `checks.<system>` item (a bullet and its indented
#   continuation lines) are exactly `checkNames`, the attribute names of the flake's checks.
{
  pkgs,
  lib,
  self,
  config,
  checkNames,
}: let
  cfg = config.programs.aiSandbox;
  phrase = "first-class Nix support";
  headings = ["Install with Nix" "Without Nix" "Options" "Ports" "Isolation" "Checks"];

  lines = lib.splitString "\n" (builtins.readFile "${self}/README.md");
  # the lines from `## <name>` up to the next level-2 heading; [] when there is no such heading
  sectionOf = name: let
    at = lib.lists.findFirstIndex (l: l == "## ${name}") null lines;
    from = lib.drop (at + 1) lines;
  in
    if at == null
    then []
    else lib.take (lib.lists.findFirstIndex (lib.hasPrefix "## ") (lib.length from) from) from;
  textOf = name: lib.concatStringsSep "\n" (sectionOf name);

  presets = lib.attrNames cfg.services;
  defaultHarnesses = lib.attrNames (lib.filterAttrs (_: h: h.enable) cfg.harnesses);

  mentions = {
    "Install with Nix" =
      ["homeModules.default" "nixosModules.default" "follows" "programs.aiSandbox.enable" "pi_notes" "_nono" "examples/existing-flake"]
      ++ defaultHarnesses
      ++ presets;
    "Without Nix" = [
      "scripts/install.sh install"
      "scripts/install.sh uninstall"
      "HARNESSES"
      "GPU"
      "ISOLATION"
      "SERVICES"
      "SERVICE_PATH"
      "XDG_CACHE_HOME"
      "--layer"
      "variant.sh"
      "examples/without-nix"
      "services-nono"
      "systemctl"
      "systemctl --user disable --now"
      "try-restart"
      "sudo tee"
      "sysctl"
      "extends"
    ];
    "Options" = ["required, no default" "nixosModules.default" "programs.aiSandbox.enable"];
    "Isolation" = ["AI_SANDBOX_RELAX" "_nono"] ++ cfg.isolation.layers;
  };

  missingWords = lib.concatLists (lib.mapAttrsToList (
      s: words: let
        t = textOf s;
      in
        map (w: "## ${s} does not mention `${w}`") (lib.filter (w: !(lib.hasInfix w t)) words)
    )
    mentions);

  missingHeadings = map (h: "no `## ${h}` heading") (lib.filter (h: sectionOf h == [] && !(lib.elem "## ${h}" lines)) headings);

  # Ports: a row names the service in backticks and each port as a whole number
  portRows = lib.filter (lib.hasPrefix "| ") (sectionOf "Ports");
  hasPort = row: port: builtins.match "(.*[^0-9])?${toString port}([^0-9].*)?" row != null;
  portProblems =
    lib.concatMap (
      s: let
        rowOk = row:
          lib.hasInfix "`${s}`" row && hasPort row cfg.services.${s}.listenPort && hasPort row cfg.services.${s}.backendPort;
      in
        lib.optional (!(lib.any rowOk portRows)) "## Ports has no row naming `${s}`, ${toString cfg.services.${s}.listenPort} and ${toString cfg.services.${s}.backendPort}"
    )
    presets;

  # Outputs: the `checks.<system>` item and its continuation lines
  outputs = sectionOf "Outputs";
  itemAt = lib.lists.findFirstIndex (lib.hasPrefix "- `checks.<system>`") null outputs;
  item = let
    rest = lib.drop (itemAt + 1) outputs;
  in
    [(lib.elemAt outputs itemAt)] ++ lib.take (lib.lists.findFirstIndex (l: !(lib.hasPrefix "  " l)) (lib.length rest) rest) rest;
  ticked = s: let
    parts = lib.splitString "`" s;
  in
    map (i: lib.elemAt parts i) (lib.filter (i: lib.mod i 2 == 1) (lib.range 0 (lib.length parts - 1)));
  listed = lib.filter (t: builtins.match "[a-z][a-z0-9-]*" t != null) (lib.concatMap ticked item);
  outputsProblems =
    if itemAt == null
    then ["## Outputs has no `- `checks.<system>`` item"]
    else
      map (n: "## Outputs does not list the check `${n}`") (lib.subtractLists listed checkNames)
      ++ map (n: "## Outputs lists `${n}`, which is not a check") (lib.subtractLists checkNames listed);

  flakeText = builtins.readFile "${self}/flake.nix";
  descriptionLine = lib.findFirst (lib.hasPrefix "  description = ") "" (lib.splitString "\n" flakeText);
  phraseProblems =
    lib.optional (!(lib.hasInfix phrase (lib.concatStringsSep "\n" lines))) "README.md does not say \"${phrase}\""
    ++ lib.optional (!(lib.hasInfix phrase descriptionLine)) "the description in flake.nix does not say \"${phrase}\"";

  problems = missingHeadings ++ missingWords ++ portProblems ++ outputsProblems ++ phraseProblems;
in
  pkgs.runCommand "readme-sections" {} (
    if problems == []
    then "touch $out"
    else "printf '%s\\n' ${lib.escapeShellArg "readme-sections:\n  ${lib.concatStringsSep "\n  " problems}"} >&2; exit 1"
  )
