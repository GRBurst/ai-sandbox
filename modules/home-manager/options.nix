{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.aiSandbox;
  sandboxLayers = import ../../packages/ai-sandbox-run/sandbox-layers.nix;
in {
  options.programs.aiSandbox = {
    enable = lib.mkEnableOption "run AI agents through the nono sandbox";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nono;
      defaultText = lib.literalExpression "pkgs.nono";
      description = "Package providing the nono sandbox CLI.";
    };

    nonoArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = ["--allow-cwd"];
      description = ''
        Extra `nono run` flags applied to every generated sandbox alias.
        `--allow-cwd` grants the working directory at the level the profile
        declares; without it nono prompts for it on every run.

        Path grants belong in the profile JSON, not here -- keeping them in one
        place is what lets the checks assert the isolation invariants against
        the resolved profile rather than against a string.
      '';
    };

    tmpdirFallback = lib.mkOption {
      type = lib.types.str;
      default = "/run/user/$UID";
      description = ''
        Root used for a sandboxed CLI's `TMPDIR` when the environment does not
        already provide one. The generated alias exports
        `''${TMPDIR:-<tmpdirFallback>}/<command>/tmp`, so a project that sets
        its own `TMPDIR` always wins and the harness writes where the project
        says.

        The value is a shell fragment, expanded by the interactive shell when
        the alias runs. `$UID` is a shell variable in both zsh and bash, so it
        costs no subprocess. Do **not** write `$XDG_RUNTIME_DIR`: this module
        redirects that variable *inside* the sandbox, so a nested invocation
        would resolve it to nvim's socket directory.

        The default is RAM-backed (logind's per-user tmpfs), mode 0700 and
        owned by the user, and removed at logout -- so the directory cannot be
        name-squatted and never accumulates. It is capped by logind's
        `RuntimeDirectorySize=`, 10% of RAM by default.

        A shared root (`/`, `/tmp`, `/var/tmp`, `/run/lock`, `/dev/shm`,
        `/run/user`), however it is spelled, is rejected by an
        assertion. `mkdir -p` neither chmods nor verifies a directory that
        already exists, so another local process could pre-create the
        intermediate `<command>` directory -- as a symlink -- and nono
        canonicalises and follows symlinks when it takes a grant. Use a 0700
        directory you own, such as `/tmp/nono-$UID`, if you need `/tmp`.
      '';
    };

    autoInstallPacks = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Set NONO_AUTO_MIGRATE so nono installs missing registry packs
        non-interactively. nono no longer ships built-in profiles, so without
        this the first sandboxed run prompts before fetching from
        registry.nono.sh.
      '';
    };

    isolation = {
      enable =
        lib.mkEnableOption ''
          the namespace isolation around nono (ai-sandbox-run): hides the user
          runtime dir, Docker/system sockets, other processes and the host /tmp,
          and makes the repo's git hooks/config read-only. Adds a `<alias>_nono`
          twin of every alias
        ''
        // {default = true;};

      layers = lib.mkOption {
        type = with lib.types; listOf (enum sandboxLayers);
        default = sandboxLayers;
        description = ''
          Isolation layers that are on by default; `AI_SANDBOX_RELAX` turns
          them off for one run.
        '';
      };
    };

    runPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../../packages/ai-sandbox-run/sandbox-run.nix {
        inherit pkgs lib;
        nono = cfg.package;
        layers = cfg.isolation.layers;
      };
      defaultText = lib.literalExpression "import ../../packages/ai-sandbox-run/sandbox-run.nix { ... }";
      description = ''
        The `ai-sandbox-run` wrapper built from `package` and `isolation.layers`: the
        namespace isolation around nono. Read-only: for modules that start a sandboxed
        command outside the generated aliases (services, login helpers).
      '';
    };

    unixMediation.enable = lib.mkEnableOption ''
      nono's pathname AF_UNIX mediation (linux.af_unix_mediation = "pathname")
      with the socket grant inventory. Off: nono 0.78.0 denies granted sockets
      (nolabs-ai/nono#1970, #1420). Stacks on the isolation, does not
      replace it
    '';

    editor = {
      enable = lib.mkEnableOption "the editor's grants in every profile (its state and cache dirs, a per-profile runtime dir)";
      appName = lib.mkOption {
        type = lib.types.str;
        default = "nvf";
        description = "The editor's NVIM_APPNAME: its XDG dirs are ~/.../<appName>.";
      };
      readFile = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        description = "Single files every profile may read when the editor grants are on (e.g. a theme mode file).";
      };
    };

    # Added to EVERY profile (harness, variant, service), after its own and its pack's grants.
    profileDefaults = {
      deny = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        description = "Paths every profile denies (defence in depth: Landlock cannot deny inside an allow).";
      };
      allow = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        description = "Read+write paths every profile is granted.";
      };
      read = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        description = "Read-only paths every profile is granted.";
      };
      readFile = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        description = "Read-only single files every profile is granted.";
      };
    };

    # A preset of `variants` (variants.nix): the twins are the variants it generates.
    gpu = {
      enable =
        lib.mkEnableOption ''
          generate a GPU-capable twin of each sandbox profile, exposed under a
          separate alias. The default aliases stay GPU-less
        ''
        // {default = true;};

      variants = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = {
          claude_gpu = "claude";
          opencode_gpu = "opencode";
        };
        description = ''
          Alias name mapped to the harness key it shadows. Each entry generates
          a `<profile>-gpu` profile carrying the same grants as its base plus
          the GPU delta, and an alias that runs the same command through it
          with `gpu.args`.

          The twin extends the same registry pack as its base rather than the
          base profile itself: `extends` in nono only ever adds, so a two-level
          lineage would weaken the one-pack-per-agent isolation boundary for no
          gain.
        '';
      };

      display = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Also grant what a *windowed* GPU application needs, not just compute:
          the X11 authority cookie and POSIX shared memory.

          This is a deliberate exception to the least-privilege rule the other
          profiles follow. X11 has no client isolation, so an agent holding a
          working display connection can log every keystroke in the session,
          screenshot any window, and inject synthetic input into unsandboxed
          terminals. Set to false for headless compute (CUDA, ROCm, llama.cpp)
          where no window is ever mapped.
        '';
      };

      args = lib.mkOption {
        type = with lib.types; listOf str;
        default = ["--allow-gpu"];
        description = ''
          Extra `nono run` flags applied to the GPU aliases only.

          `--allow-gpu` must stay here rather than in `nonoArgs`: nono requires
          the flag *and* `allow_gpu` in the resolved profile, so putting it in
          `nonoArgs` would make every non-GPU alias fail closed instead of
          merely running without a GPU.
        '';
      };
    };

    extraAliases = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = {};
      description = ''
        Additional AI aliases. Overrides a generated sandbox alias of the same
        name, which is how a single tool gets extra `nono run` flags.
      '';
    };
  };
}
