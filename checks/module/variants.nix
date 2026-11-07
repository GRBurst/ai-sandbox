# Variants: an alias layered on a harness with a grant delta, and the GPU twins
# as the preset that generates today's two variants. Over the standalone fixtures of ./lib.nix;
# wired by ./default.nix as ai-sandbox-variants.
{
  lib,
  helpers,
}: let
  inherit (helpers) mkAssertionCheck aiFixtureWith aiNoNvf aiEmittedProfiles aiAliasString aiWrapperArgv aiExpectedNonoAlias aiFailedWith aiFailsWith;
  emitted = h: aiEmittedProfiles h.config;
  rename = name: p: lib.recursiveUpdate p {meta.name = name;};

  piNotes = aiFixtureWith {
    programs.aiSandbox.variants.pi_notes = {
      harness = "pi";
      suffix = "notes";
      allow = ["$HOME/src/notes"];
    };
  };
  base = emitted aiNoNvf;
  pn = emitted piNotes;

  # What the GPU delta is, literally (the display branch is on by default): the twin of a profile
  # is the profile plus these grants, one `allow_gpu`, and DISPLAY no longer stripped.
  gpuTwin = name: p:
    rename name (lib.recursiveUpdate p {
      allow_gpu = true;
      filesystem = {
        allow = p.filesystem.allow ++ ["/dev/shm"];
        read = (p.filesystem.read or []) ++ ["/run/udev"];
        read_file = (p.filesystem.read_file or []) ++ ["$HOME/.Xauthority"];
      };
      environment.deny_vars = lib.remove "DISPLAY" p.environment.deny_vars;
    });

  # The same twin spelled as a generic variant.
  asVariant = aiFixtureWith {
    programs.aiSandbox.variants.claude_win = {
      harness = "claude";
      suffix = "win";
      allowGpu = true;
      x11 = true;
      nonoArgs = ["--allow-gpu"];
    };
  };
  shared = aiFixtureWith {
    programs.aiSandbox.variants = {
      a = {
        harness = "claude";
        suffix = "x";
        allow = ["/srv/x"];
      };
      b = {
        harness = "claude";
        suffix = "x";
        allow = ["/srv/x"];
      };
    };
  };
  ofDisabledModule = {
    programs.aiSandbox.harnesses.agy.enable = false;
    programs.aiSandbox.variants.agy_x = {
      harness = "agy";
      suffix = "x";
    };
  };
  ofDisabled = aiFixtureWith ofDisabledModule;
  gitVarModule = {
    programs.aiSandbox.variants.dot = {
      harness = "claude";
      suffix = "dot";
      allow = ["$HOME/src/dot.git"];
      gitDirs = ["$HOME/src/dot.git" "/srv/b.git"];
    };
  };
  gitVar = aiFixtureWith gitVarModule;
  # The gpu preset's leaves are defaults: a consumer renames one twin's suffix.
  gpuRenamed = emitted (aiFixtureWith {programs.aiSandbox.variants.claude_gpu.suffix = "mine";});
in
  mkAssertionCheck "ai-sandbox-variants" [
    {
      # profile(v) = profile(harness v) + delta(v): one `extends`, only the name and the added
      # grant differ.
      condition =
        pn ? pi-claude-notes
        && pn.pi-claude-notes.extends == base.pi-claude.extends
        && pn.pi-claude-notes
        == rename "pi-claude-notes" (lib.recursiveUpdate base.pi-claude {
          filesystem.allow = base.pi-claude.filesystem.allow ++ ["$HOME/src/notes"];
        });
      message = "variants.pi_notes must emit pi-claude-notes = pi-claude plus the allow grant";
    }
    {
      condition = removeAttrs pn ["pi-claude-notes"] == base;
      message = "adding a variant must leave every other profile byte-equal";
    }
    {
      # `pi_notes` runs the harness's command (so its TMPDIR leaf is the harness's) through the
      # variant's profile; its `_nono` twin is the nono-only string.
      condition = let
        a = piNotes.config.home.shellAliases;
        profile = "pi-claude-notes";
      in
        a.pi_notes
        == aiAliasString (aiWrapperArgv {
          alias = "pi_notes";
          inherit profile;
        }) []
        piNotes.config
        "pi"
        profile
        && a.pi_notes_nono == aiExpectedNonoAlias piNotes.config "pi" profile
        && a.pi == aiNoNvf.config.home.shellAliases.pi;
      message = "variants.pi_notes must add the aliases pi_notes and pi_notes_nono and leave pi alone";
    }
    {
      # `gpu.*` is the preset: today's two twins are their base profile plus the GPU delta.
      condition =
        base
        ? claude-local-gpu
        && base.claude-local-gpu == gpuTwin "claude-local-gpu" base.claude-local
        && base.opencode-claude-gpu == gpuTwin "opencode-claude-gpu" base.opencode-claude
        && lib.attrNames (lib.filterAttrs (n: _: lib.hasSuffix "-gpu" n) base) == ["claude-local-gpu" "opencode-claude-gpu"];
      message = "the gpu preset must generate exactly the claude-local-gpu and opencode-claude-gpu twins (base plus the GPU delta)";
    }
    {
      # A generic variant with allowGpu and x11 IS the twin.
      condition = let
        p = emitted asVariant;
      in
        p.claude-local-win
        == rename "claude-local-win" base.claude-local-gpu
        && asVariant.config.home.shellAliases.claude_win
        == aiAliasString (aiWrapperArgv {
          alias = "claude_win";
          profile = "claude-local-win";
          x11 = true;
        }) ["--allow-gpu"]
        asVariant.config
        "claude"
        "claude-local-win";
      message = "a variant with allowGpu, x11 and nonoArgs must equal the GPU twin of its harness";
    }
    {
      # Two aliases on one (harness, suffix) share the profile.
      condition = let
        p = emitted shared;
      in
        lib.length (lib.filter (n: n == "claude-local-x") (lib.attrNames p))
        == 1
        && shared.config.home.shellAliases ? a
        && shared.config.home.shellAliases ? b_nono;
      message = "variants on the same harness and suffix must share one profile and each get their aliases";
    }
    {
      # Switching a harness off drops its variants, as it drops its GPU twin.
      condition = let
        p = emitted ofDisabled;
      in
        !(p ? agy-local-x) && !(ofDisabled.config.home.shellAliases ? agy_x) && aiFailedWith ofDisabledModule == [];
      message = "a variant of a disabled harness must be dropped silently";
    }
    {
      condition = aiFailsWith "ai-sandbox: programs.aiSandbox.variants names a harness that does not exist" {
        programs.aiSandbox.variants.bogus = {
          harness = "no-such-harness";
          suffix = "x";
        };
      };
      message = "a variant naming no harness must fail exactly the variants module assertion";
    }
    {
      # Two variants on one (harness, suffix) share the profile, so their profile deltas must be
      # equal: otherwise one alias would silently run with the other's grants.
      condition =
        aiFailsWith "ai-sandbox: programs.aiSandbox.variants a, b share the profile claude-local-x" {
          programs.aiSandbox.variants = {
            a = {
              harness = "claude";
              suffix = "x";
              allow = ["/srv/a"];
            };
            b = {
              harness = "claude";
              suffix = "x";
              allowGpu = true;
              nonoArgs = ["--allow-gpu"];
            };
          };
        }
        && aiFailedWith {
          programs.aiSandbox.variants = {
            a = {
              harness = "claude";
              suffix = "x";
              allow = ["/srv/x"];
            };
            b = {
              harness = "claude";
              suffix = "x";
              allow = ["/srv/x"];
            };
          };
        }
        == [];
      message = "variants sharing a profile with different deltas must fail the module assertion (equal deltas pass)";
    }
    {
      condition = gpuRenamed ? claude-local-mine && !(gpuRenamed ? claude-local-gpu) && gpuRenamed ? opencode-claude-gpu;
      message = "the gpu preset's variant leaves are defaults a consumer can override (suffix)";
    }
    {
      # gitDirs: the alias hands each to the wrapper (`--git-dir`, double-quoted so `$HOME`
      # expands), names no `_nono` twin in the hint, and has none: nono alone would leave the
      # git dir's hooks and config writable.
      condition = let
        a = gitVar.config.home.shellAliases;
        profile = "claude-local-dot";
      in
        a.dot
        == aiAliasString ["ai-sandbox-run" "--git-dir" "\"$HOME/src/dot.git\"" "--git-dir" "\"/srv/b.git\"" "--open-urls-profile" profile "--"] []
        gitVar.config
        "claude"
        profile
        && !(a ? dot_nono)
        && a ? claude_nono
        && aiFailedWith gitVarModule == [];
      message = "a variant with gitDirs must pass them to ai-sandbox-run as --git-dir and get no _nono twin";
    }
    {
      condition =
        aiFailsWith "ai-sandbox: programs.aiSandbox.variants dot set gitDirs" (lib.recursiveUpdate gitVarModule {programs.aiSandbox.isolation.enable = false;})
        && aiFailsWith "ai-sandbox: programs.aiSandbox.variants dot set gitDirs" (lib.recursiveUpdate gitVarModule {programs.aiSandbox.isolation.layers = ["pid" "tmp"];});
      message = "gitDirs without the isolation, or without its git layer, must fail the variants module assertion";
    }
    {
      condition = lib.all (d:
        aiFailsWith "ai-sandbox: programs.aiSandbox.variants.<name>.gitDirs entries" {
          programs.aiSandbox.variants.dot = {
            harness = "claude";
            suffix = "dot";
            gitDirs = [d];
          };
        }) ["src/dot.git" "~/dot.git" "/srv/a'b" "/srv/$(id)" "$HOME/x\"y" "/srv/a\\b"];
      message = "a gitDirs entry that is not absolute or $HOME/..., or holds a shell metacharacter, must fail the module assertion";
    }
  ]
