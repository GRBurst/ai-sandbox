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
        preStart = lib.mkOption {
          type = lib.types.lines;
          default = "";
          example = lib.literalExpression ''
            '''
              ''${pkgs.my-service}/bin/my-service-up
              export MY_SERVICE_URL=http://127.0.0.1:8080
            '''
          '';
          description = ''
            POSIX `sh` lines sourced by every generated alias of this harness (`<name>`, its
            `_nono` twin, its variants and their twins; not `extraAliases` and not `render.command`)
            OUTSIDE the sandbox, after the alias creates its TMPDIR and before it `exec`s the
            sandboxed command. What they export reaches the harness. Stdin is `/dev/null` and
            stdout goes to stderr, so a piped prompt and the harness's output stay intact. A
            failing command does not stop the harness; `exit` does (the alias ends with that
            status). Do not leave `set -e` on: whether it stops the harness depends on the shell
            (`dash` aborts, `bash` as `sh` ignores it inside `|| :`). The lines run in the alias's
            own shell: `cd` changes the harness's working directory (and its `--allow-cwd` grant),
            and `set --` or `shift` clobbers the arguments; do not use them (a `( ... )` subshell
            keeps a `cd` to itself, but exports nothing back). A background process started here
            must detach stdin, stdout and stderr (`cmd >/dev/null 2>&1 </dev/null &`), or
            `... 2>&1 | jq` waits for it. The lines are checked
            with `dash -n` at build time; TMPDIR is the harness's own (writable by the sandbox), so
            a long-lived process started here should get a TMPDIR of its own. To run a script
            rather than lines, write `. ''${script}` (sourced: its exports reach the harness) or
            `''${script}` (a child process: they do not). Empty or blank: no hook, the aliases are
            unchanged. Nix only: the files rendered for use without Nix carry no hook.
          '';
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
    # Reaches Claude through Claude Code's credentials in a config dir of opencode's own,
    # which its base (./bases.nix) sets and grants; nothing under ~/.claude.
    opencode = {
      profileName = "opencode-claude";
      pack = "nolabs-ai/opencode";
      exclude = ["user_caches_linux"];
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
        Grants and variables added to EVERY profile (harness, GPU twin, service) of the named
        registry pack (its `pack`), so a pack-level need is stated once.
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
