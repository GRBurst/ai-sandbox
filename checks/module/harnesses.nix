# Harness presets and per-pack defaults, over the standalone
# fixtures of ./lib.nix. Wired by ./default.nix as ai-sandbox-harnesses.
{
  lib,
  pkgs,
  helpers,
}: let
  inherit (helpers) mkAssertionCheck aiFixtureWith aiEmittedProfiles aiGpuVariants aiBasePack;
  harnesses = ["agy" "claude" "opencode" "pi"];
  base = (aiFixtureWith {}).config;
  baseProfiles = aiEmittedProfiles base;
  baseAliases = base.home.shellAliases;
  profileOf = h: x: h.programs.aiSandbox.harnessProfiles.${x};
  off = x: (aiFixtureWith {programs.aiSandbox.harnesses.${x}.enable = false;}).config;

  # What disabling harness x must remove: its profile and GPU twin, the ai-sandbox base of its
  # pack (no other default profile has that pack), its alias, its `_nono` twin, and the
  # aliases of the variants of x with their twins.
  gonePrefix = x: [x] ++ lib.attrNames (lib.filterAttrs (_: c: c == x) aiGpuVariants);
  goneProfiles = x: let
    p = profileOf base x;
  in
    [p]
    ++ lib.optional (lib.any (c: c == x) (lib.attrValues aiGpuVariants)) "${p}-gpu"
    ++ lib.attrNames (lib.filterAttrs (_: pack: pack == base.programs.aiSandbox.harnesses.${x}.pack) aiBasePack);
  goneAliases = x: lib.concatMap (a: [a "${a}_nono"]) (gonePrefix x);

  switchOff = x: let
    h = off x;
  in
    aiEmittedProfiles h
    == removeAttrs baseProfiles (goneProfiles x)
    && h.home.shellAliases == removeAttrs baseAliases (goneAliases x);

  # A delta on a test pack, one entry in every grant field, reaches every emitted profile
  # of that pack (harness and GPU twin alike) and no other; the pack is re-based, so its
  # profiles extend its ai-sandbox base, which the delta must not reach either.
  testPack = "nolabs-ai/claude";
  testBase = lib.findFirst (b: aiBasePack.${b} == testPack) testPack (lib.attrNames aiBasePack);
  packDelta = {
    allow = ["$HOME/.pack-allow"];
    allowFile = ["$HOME/.pack-delta"];
    read = ["$HOME/.pack-read"];
    readFile = ["$HOME/.pack-read-file"];
    deny = ["$HOME/.pack-deny"];
    setVars.PACK_DELTA = "1";
    unixSocketSubtreeBind = ["$HOME/.pack-sock"];
  };
  withDelta = (aiFixtureWith {programs.aiSandbox.packDefaults.${testPack} = packDelta;}).config;
  deltaProfiles = aiEmittedProfiles withDelta;
  # The socket grant is emitted only under mediation.
  mediated =
    aiEmittedProfiles
    (aiFixtureWith {
      programs.aiSandbox.unixMediation.enable = true;
      programs.aiSandbox.packDefaults.${testPack} = packDelta;
    }).config;
  extendsPack = p: p.extends == [testBase];
  hasDelta = p: let
    fs = p.filesystem;
  in
    lib.elem "$HOME/.pack-allow" fs.allow
    && lib.elem "$HOME/.pack-delta" (fs.allow_file or [])
    && lib.elem "$HOME/.pack-read" (fs.read or [])
    && lib.elem "$HOME/.pack-read-file" (fs.read_file or [])
    && lib.elem "$HOME/.pack-deny" (fs.deny or [])
    && (p.environment.set_vars.PACK_DELTA or null) == "1";
  hasAny = p: let
    fs = p.filesystem;
  in
    lib.any (g: lib.elem g (fs.allow ++ fs.allow_file or [] ++ fs.read or [] ++ fs.read_file or [] ++ fs.deny or [] ++ fs.unix_socket_subtree_bind or []))
    ["$HOME/.pack-allow" "$HOME/.pack-delta" "$HOME/.pack-read" "$HOME/.pack-read-file" "$HOME/.pack-deny" "$HOME/.pack-sock"]
    || p.environment.set_vars ? PACK_DELTA;

  # profileDefaults: grants added to every profile of every pack (harness, GPU twin, service);
  # not to an ai-sandbox base, which stays the pack's profile (its profiles carry them).
  defaults =
    removeAttrs
    (aiEmittedProfiles
      (aiFixtureWith {
        programs.aiSandbox.profileDefaults = {
          allow = ["$HOME/.all-allow"];
          read = ["$HOME/.all-read"];
          readFile = ["$HOME/.all-read-file"];
          deny = ["$HOME/.all-deny"];
        };
        programs.aiSandbox.services.opencode-web.enable = true;
      })
      .config)
    (lib.attrNames aiBasePack);

  # `harnesses.<n>.package` is installed iff it is non-null and the harness is enabled.
  stub = pkgs.writeShellScriptBin "opencode" "exit 0";
  packagesWith = opencode: (aiFixtureWith {programs.aiSandbox.harnesses.opencode = opencode;}).config.home.packages;
  allOff = (aiFixtureWith {programs.aiSandbox.harnesses = lib.genAttrs harnesses (_: {enable = false;});}).config;
in
  mkAssertionCheck "ai-sandbox-harnesses" ([
      {
        condition = let
          ps = packagesWith {package = stub;};
          at = p: lib.lists.findFirstIndex (x: x == p) null ps;
        in
          lib.elem stub ps
          && lib.remove stub ps == base.home.packages
          && at stub == at base.programs.aiSandbox.runPackage + 1;
        message = "harnesses: an enabled harness's package is installed right after ai-sandbox-run, and nothing else with it";
      }
      {
        condition =
          !(lib.elem stub (packagesWith {
            package = stub;
            enable = false;
          }));
        message = "harnesses: a disabled harness's package is not installed";
      }
      {
        condition = lib.all (h: h.package == null) (lib.attrValues base.programs.aiSandbox.harnesses) && base.home.packages == allOff.home.packages;
        message = "harnesses: a harness with package = null (the default) installs nothing";
      }
      {
        condition = lib.attrNames (lib.filterAttrs (_: h: h.enable) base.programs.aiSandbox.harnesses) == harnesses;
        message = "harnesses: the presets are exactly agy, claude, opencode and pi, all on";
      }
      {
        condition = lib.all (x: baseAliases ? ${x}) harnesses;
        message = "harnesses: every preset harness gets its alias";
      }
      {
        condition = lib.filterAttrs (_: extendsPack) deltaProfiles != {} && lib.all hasDelta (lib.attrValues (lib.filterAttrs (_: extendsPack) deltaProfiles));
        message = "harnesses: packDefaults reach every profile extending the pack, GPU twins included";
      }
      {
        condition = lib.all (p: lib.elem "$HOME/.pack-sock" p.filesystem.unix_socket_subtree_bind) (lib.attrValues (lib.filterAttrs (_: extendsPack) mediated));
        message = "harnesses: packDefaults.<pack>.unixSocketSubtreeBind reaches every profile of the pack under mediation";
      }
      {
        condition = lib.all (p: !(hasAny p)) (lib.attrValues (lib.filterAttrs (_: p: !(extendsPack p)) deltaProfiles) ++ lib.attrValues (lib.filterAttrs (_: p: !(extendsPack p)) mediated));
        message = "harnesses: packDefaults of one pack reach no profile of another pack";
      }
      {
        condition = lib.all (n: deltaProfiles.${n} == baseProfiles.${n}) (lib.attrNames (lib.filterAttrs (_: p: !(extendsPack p)) deltaProfiles));
        message = "harnesses: a packDefaults delta leaves every other profile byte-identical";
      }
      {
        condition = let
          fs = map (p: p.filesystem) (lib.attrValues defaults);
        in
          defaults ? opencode-web
          && lib.all (f:
            lib.elem "$HOME/.all-allow" f.allow
            && lib.elem "$HOME/.all-read" (f.read or [])
            && lib.elem "$HOME/.all-read-file" (f.read_file or [])
            && lib.elem "$HOME/.all-deny" f.deny)
          fs;
        message = "profileDefaults.{allow,read,readFile,deny} reach every emitted profile (harnesses, GPU twins, services)";
      }
    ]
    ++ map (x: {
      condition = switchOff x;
      message = "harnesses: switching off ${x} removes exactly its profile, GPU twin and aliases and nothing else";
    })
    harnesses)
