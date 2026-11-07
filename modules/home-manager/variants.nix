# Variants: an alias layered on a harness, with a grant delta, optionally with GPU access and
# the host's X11 socket. `gpu.*` is the preset that generates the GPU twins.
# A variant's profile is `<harness profile>-<suffix>`: the harness's profile arguments plus the
# delta, extending the same single registry pack (profiles.nix emits it).
{
  config,
  lib,
  ...
}: let
  cfg = config.programs.aiSandbox;
  grantFields = import ./grants.nix {inherit lib;};

  variantType = lib.types.submodule {
    options =
      grantFields
      // {
        harness = lib.mkOption {
          type = lib.types.str;
          description = "The harness (key of `harnesses`) this variant is layered on.";
        };
        suffix = lib.mkOption {
          type = lib.types.str;
          description = "Appended to the harness's profile name: `<profileName>-<suffix>`. Variants of one harness with the same suffix share the profile.";
        };
        allowGpu = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Grant the GPU: `allow_gpu` in the profile and read access to `/run/udev` (device enumeration).";
        };
        x11 = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            A windowed application: the X11 authority cookie (read-only) and POSIX shared memory,
            DISPLAY no longer stripped, the X server's socket dir under unix mediation, and the
            host's X11 socket dir bound into the alias's private /tmp (`--x11`). X11 has no client
            isolation: an agent with a working display connection can log keystrokes and inject input.
          '';
        };
        nonoArgs = lib.mkOption {
          type = with lib.types; listOf str;
          default = [];
          description = "Extra `nono run` flags of this variant's alias only (the GPU flag belongs here, never in `nonoArgs` of the module).";
        };
        gitDirs = lib.mkOption {
          type = with lib.types; listOf str;
          default = [];
          example = ["$HOME/src/config.git"];
          description = ''
            Git directories besides the project's own `.git` that this variant writes to, such as
            a bare repository the agent commits to (grant it in `allow` as well; this option grants
            nothing). The isolation wrapper holds each one's `hooks/`, `config`, `config.worktree`,
            `info/`, in-tree config includes and its linked worktrees' `config.worktree`,
            `commondir` and `gitdir` read-only, as it does the project's `.git`, so
            objects and refs stay writable but nothing the agent writes there runs outside the
            sandbox. Absolute or `$HOME/...`, expanded when the alias runs. The wrapper refuses to
            start if one is missing, has no `hooks/` directory or has a `commondir` file. Needs
            the namespace isolation with its `git` layer; such a variant gets no `<alias>_nono`
            twin, since nono alone cannot hold them read-only.
          '';
        };
      };
  };

  # A variant of a disabled harness is dropped silently, like its GPU twin; one naming no harness
  # at all is an assertion (aliases.nix).
  live = lib.filterAttrs (_: v: cfg.harnessProfiles ? ${v.harness}) cfg.variants;

  # Variants on one (harness, suffix) share one profile, so they must agree on everything that
  # goes into it (all but the alias-only `nonoArgs`); otherwise an alias would silently run with
  # another alias's grants.
  profileOf = v: "${cfg.harnessProfiles.${v.harness}}-${v.suffix}";
  byProfile = lib.groupBy (a: profileOf live.${a}) (lib.attrNames live);
  clashes =
    lib.filterAttrs (_: as: lib.length (lib.unique (map (a: removeAttrs live.${a} ["nonoArgs"]) as)) > 1)
    byProfile;

  # gitDirs is enforced by the isolation wrapper's git layer only, and lands in a shell string
  # inside single and double quotes: no quote, backtick, `$` (but the leading `$HOME/`) or backslash.
  withGitDirs = lib.filterAttrs (_: v: v.gitDirs != []) live;
  gitLayerOn = cfg.isolation.enable && lib.elem "git" cfg.isolation.layers;
  badGitDirs = lib.filter (d: builtins.match "(/|[$]HOME/)[^'\"`$\\\n]*" d == null) (lib.concatMap (v: v.gitDirs) (lib.attrValues withGitDirs));
in {
  options.programs.aiSandbox = {
    variants = lib.mkOption {
      type = lib.types.attrsOf variantType;
      default = {};
      description = ''
        Extra aliases layered on a harness: the attribute is the alias, `harness` the command it
        runs. Each generates the profile `<profileName>-<suffix>` (the harness's grants plus the
        delta given here) and the aliases `<alias>` and `<alias>_nono` (no `_nono` twin with `gitDirs`).
      '';
    };

    internal.variants = lib.mkOption {
      type = with lib.types; attrsOf attrs;
      internal = true;
      readOnly = true;
      description = "Alias mapped to `{command, profile, spec}` for the variants of enabled harnesses.";
    };
  };

  config = {
    programs.aiSandbox = {
      # The preset: today's twins, `<profile>-gpu`, with the module's GPU switches (per-leaf
      # defaults, so a consumer can override one leaf of a twin).
      variants = lib.mkIf (cfg.enable && cfg.gpu.enable) (lib.mapAttrs (_: command:
        lib.mapAttrs (_: lib.mkDefault) {
          harness = command;
          suffix = "gpu";
          allowGpu = true;
          x11 = cfg.gpu.display;
          nonoArgs = cfg.gpu.args;
        })
      cfg.gpu.variants);

      internal.variants =
        lib.mapAttrs (_: v: {
          command = v.harness;
          profile = profileOf v;
          spec = v;
        })
        live;
    };

    assertions =
      [
        {
          assertion = withGitDirs == {} || gitLayerOn;
          message = ''
            ai-sandbox: programs.aiSandbox.variants ${lib.concatStringsSep ", " (lib.attrNames withGitDirs)} set gitDirs, which only the namespace isolation's git layer holds read-only. Turn on isolation.enable with "git" in isolation.layers, or drop gitDirs (and the grant on those directories).
          '';
        }
        {
          assertion = badGitDirs == [];
          message = ''
            ai-sandbox: programs.aiSandbox.variants.<name>.gitDirs entries must be absolute or start with $HOME/, and contain no quote, backtick, backslash, newline or other `$` (got: ${lib.concatStringsSep ", " badGitDirs}).
          '';
        }
      ]
      ++ lib.mapAttrsToList (profile: as: {
        assertion = false;
        message = ''
          ai-sandbox: programs.aiSandbox.variants ${lib.concatStringsSep ", " as} share the profile ${profile} (same harness and suffix) but differ in its grants. Give them distinct suffixes, or the same delta.
        '';
      })
      clashes;
  };
}
