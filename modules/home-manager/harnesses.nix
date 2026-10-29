# Harnesses (the agent CLIs that get a sandbox profile and an alias) and per-pack defaults.
# Each harness extends exactly one nono registry pack (one pack per agent). Presets are
# set per leaf with mkDefault, so a consumer overrides one field without restating the rest.
{
  config,
  lib,
  ...
}: let
  cfg = config.programs.aiSandbox;
  grantFields = import ./grants.nix {inherit lib;};

  harnessType = lib.types.submodule {
    options =
      import ./profile-options.nix {inherit lib;}
      // {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Generate this harness's profile and aliases.";
        };
        profileName = lib.mkOption {
          type = lib.types.str;
          description = "Name of the generated nono profile (the `<command>_gpu`-style twins add a suffix).";
        };
        package = lib.mkOption {
          type = with lib.types; nullOr package;
          default = null;
          description = "The harness's CLI, appended to `home.packages` while the harness and the module (`programs.aiSandbox.enable`) are enabled; `null` installs nothing (the CLI comes from elsewhere). The aliases run the bare command `<name>` from `PATH`, so the package must provide `bin/<name>`.";
        };
      };
  };

  # Per-leaf mkDefault of the presets.
  presets = {
    # Google's terminal agent. Deliberately no Claude grant of any kind: it authenticates
    # against Google. The pack is macOS-first (empty groups.include), so the two groups
    # an exec of a /nix/store binary needs are added; user_caches_linux is NOT added.
    agy = {
      profileName = "agy-local";
      pack = "nolabs-ai/antigravity";
      include = ["nix_runtime" "git_config"];
      readsSharedSkills = true;
    };
    claude = {
      profileName = "claude-local";
      pack = "nolabs-ai/claude";
      exclude = ["vscode_linux"];
    };
    # Reads Claude Code's OAuth credentials, refreshes them and writes the rotated refresh
    # token back: rw on that one file, not on the whole ~/.claude directory.
    opencode = {
      profileName = "opencode-claude";
      pack = "nolabs-ai/opencode";
      exclude = ["user_caches_linux"];
      allowFile = ["$HOME/.claude/.credentials.json"];
      readsSharedSkills = true;
    };
    pi = {
      profileName = "pi-claude";
      pack = "nolabs-ai/pi";
      exclude = ["user_caches_linux"];
    };
  };
in {
  options.programs.aiSandbox = {
    harnesses = lib.mkOption {
      type = lib.types.attrsOf harnessType;
      default = {};
      description = ''
        The harnesses, by command name (the attribute is the command and the alias).
        Every enabled one gets a profile and an alias (plus a `_nono` twin and, for the
        GPU variants, GPU twins). Add a sandboxed tool by adding one attribute.
      '';
    };

    packDefaults = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {options = grantFields;});
      default = {};
      description = ''
        Grants and variables added to EVERY profile (harness, GPU twin, service) that extends
        the named registry pack, so a pack-level need is stated once.
      '';
    };

    sharedSkillsDir = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.agents/skills";
      description = ''
        The cross-tool skills tree. Read-only everywhere: it is loaded into every harness's
        prompt, so a writable grant would be a cross-harness injection channel.
      '';
    };

    harnessProfiles = lib.mkOption {
      type = with lib.types; attrsOf str;
      readOnly = true;
      description = ''
        The command of every enabled harness mapped to its nono profile name, e.g.
        `{ claude = "claude-local"; }`. Read-only: for modules that run a harness's
        command in its profile (`render.command`) or grant its profile something.
        Independent of `programs.aiSandbox.enable`: the enabled harnesses are listed even
        while the module is off, when no profile is emitted. GPU twins (`<profile>-gpu`)
        and `variants` (`<profile>-<suffix>`) are not included.
      '';
    };
  };

  config.programs.aiSandbox = {
    harnesses = lib.mapAttrs (_: lib.mapAttrs (_: lib.mkDefault)) presets;
    harnessProfiles = lib.mapAttrs (_: h: h.profileName) (lib.filterAttrs (_: h: h.enable) cfg.harnesses);
  };
}
