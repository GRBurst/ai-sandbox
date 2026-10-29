# What the sandbox module does to the home itself: the packages it installs,
# the session variable that lets nono install its packs, and the directories activation
# creates. Over the standalone fixtures of ./lib.nix; wired by ./default.nix as
# ai-sandbox-home.
{
  lib,
  pkgs,
  helpers,
}: let
  inherit (helpers) mkAssertionCheck aiNoNvf aiFixtureWith;
  names = hm: map (p: p.pname or p.name or "") hm.home.packages;
  on = aiNoNvf.config;
  noIso = (aiFixtureWith {programs.aiSandbox.isolation.enable = false;}).config;
  off = (aiFixtureWith {programs.aiSandbox.enable = false;}).config;
  noPacks = (aiFixtureWith {programs.aiSandbox.autoInstallPacks = false;}).config;
  editor = (aiFixtureWith {programs.aiSandbox.editor.enable = true;}).config;
  dirs = hm: hm.home.activation.aiSandboxDirs.data or "";
  install = d: "run install -d -m 0700 \"${d}\"";
  commands = ["agy" "claude" "opencode" "pi"];
  profiles = ["agy-local" "claude-local" "opencode-claude" "pi-claude"];
  allProfiles = profiles ++ ["claude-local-gpu" "opencode-claude-gpu"];
in
  mkAssertionCheck "ai-sandbox-home" [
    {
      # The nono package and the wrapper are the module's own packages; the wrapper only
      # while the isolation is on, nothing while the module is off.
      condition =
        lib.elem pkgs.hello.name (map (p: p.name) on.home.packages)
        && lib.elem "ai-sandbox-run" (names on)
        && !(lib.elem "ai-sandbox-run" (names noIso))
        && lib.elem pkgs.hello.name (map (p: p.name) noIso.home.packages)
        && !(lib.elem pkgs.hello.name (map (p: p.name) off.home.packages))
        && !(lib.elem "ai-sandbox-run" (names off));
      message = "ai-sandbox home: package and ai-sandbox-run installed, the wrapper only with the isolation, nothing when disabled";
    }
    {
      condition =
        on.home.sessionVariables.NONO_AUTO_MIGRATE or null
        == "1"
        && !(noPacks.home.sessionVariables ? NONO_AUTO_MIGRATE)
        && !(off.home.sessionVariables ? NONO_AUTO_MIGRATE);
      message = "ai-sandbox home: NONO_AUTO_MIGRATE=1 follows autoInstallPacks and the enable switch";
    }
    {
      # nono grants paths but never creates them: every harness's persistent cache dir must exist
      # (0700, install -d re-modes an existing one), and the private tmpdirs must NOT be made
      # here -- the alias creates them.
      condition =
        lib.all (c: lib.hasInfix (install "/tmp/ai-test/.cache/${c}") (dirs on)) commands
        && !(lib.hasInfix "/claude/tmp" (dirs on))
        && !(lib.hasInfix "/run-" (dirs on))
        && !(off.home.activation ? aiSandboxDirs);
      message = "ai-sandbox home: aiSandboxDirs creates 0700 cache dirs for every harness, no tmpdirs, no runtime dirs without the editor";
    }
    {
      # With the editor grants every emitted profile (GPU twins included) gets its own runtime
      # dir under the editor's state dir.
      condition = lib.all (p: lib.hasInfix (install "/tmp/ai-test/.local/state/nvf/run-${p}") (dirs editor)) allProfiles;
      message = "ai-sandbox home: with the editor grants every profile gets a runtime dir under the editor's state dir";
    }
    {
      # The installer's dir list is `internal.activationDirs`; activation must create exactly it.
      condition =
        lib.all (h: h.programs.aiSandbox.internal.activationDirs != [] && dirs h == lib.concatMapStringsSep "\n" install h.programs.aiSandbox.internal.activationDirs) [on editor]
        && off.programs.aiSandbox.internal.activationDirs == [];
      message = "ai-sandbox home: aiSandboxDirs installs exactly internal.activationDirs (0700), none while disabled";
    }
  ]
