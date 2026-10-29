# The shell aliases: `<command>` through the namespace isolation and nono, its `_nono` twin
# (nono only), the GPU variants and their twins, `extraAliases`, and `render.command` for
# consumers that build a sandboxed command line themselves.
{
  config,
  lib,
  ...
}: let
  scfg = config.programs.aiSandbox;
  isolationEnabled = scfg.enable && scfg.isolation.enable;

  # A SHELL EXPRESSION, not a path: expanded by the interactive shell when the
  # alias runs, so a project that exports its own TMPDIR wins and the harness
  # writes where the project says.
  #
  # Set BEFORE nono, never in the profile: the packs' `filesystem.allow` entry
  # `$TMPDIR` is expanded from the inherited environment at profile-resolution
  # time, before the sandbox is entered (verified: `TMPDIR=d nono profile show p`
  # yields `$TMPDIR -> d`). This is what turns the opencode pack's read+write on
  # ALL of /tmp -- which otherwise reaches /tmp/claude-$UID, /tmp/jiti and
  # /tmp/.X11-unix -- into a private per-CLI directory. The grant is inherited
  # and unremovable, so what $TMPDIR expands to is the only lever available.
  #
  # Independent of the namespace isolation (ai-sandbox-run), whose `tmp` layer
  # makes /tmp private: this is what still bounds the grant under the
  # `<alias>_nono` twins, with AI_SANDBOX_RELAX=tmp, and for a TMPDIR outside
  # /tmp. The wrapper binds TMPDIR back into its tmpfs'd runtime dir and /tmp.
  #
  # Must stay alias-scoped -- home.sessionVariables would move the real desktop
  # session's TMPDIR too.
  #
  # `:-` and not `-`: an exported-but-empty TMPDIR has to fall back as well.
  #
  # THE `/<command>/tmp` LEAF IS LOAD-BEARING. It is what makes the profile's
  # `$TMPDIR` grant safe for *any* ambient value. Without it, `nix develop` --
  # which sets TMPDIR=/run/user/$UID (NixOS/nix#10430) -- would make that grant
  # resolve to gnome-keyring's secrets+ssh sockets and the session D-Bus socket,
  # and an unset TMPDIR would resolve it to all of /tmp. The leaf also keeps the
  # per-CLI tmpdirs pairwise distinct. Asserted by the checks.
  sandboxTmpdirExpr = command: "\${TMPDIR:-${scfg.tmpdirFallback}}/${command}/tmp";

  # "claude" ->
  #   TMPDIR="${TMPDIR:-/run/user/$UID}/claude/tmp" sh -c 'mkdir -p -m 700
  #   "$TMPDIR" && exec ai-sandbox-run --nono-alias claude_nono
  #   --open-urls-profile claude-local -- nono run --profile claude-local
  #   --allow-cwd -- claude "$@"' claude
  # and its twin claude_nono, the same without the `ai-sandbox-run ... --`.
  #
  # ONE command, deliberately not `mkdir ... && nono ...`. An `&&` list would
  # break `echo prompt | claude -p`: the pipeline's second element would be
  # mkdir, and nono would then inherit the terminal instead of the pipe. `sh -c`
  # keeps the alias a single pipeline element, `exec` keeps it a single process,
  # and `"$@"` picks up the arguments the shell appends after an alias. A
  # `{ ...; }` brace group cannot be used instead: those appended arguments
  # would land after the `}` and be a syntax error.
  #
  # The prefix assignment is exported into sh's environment, so `$TMPDIR` inside
  # the script is the value computed on the left -- the expression appears once.
  #
  # `mkdir -p -m 700`, not `install -d -m 700`: install chmods components that
  # already exist, which in the ambient branch would silently re-mode a
  # project's own temp directory. The leaf holds the data and gets 0700.
  #
  # nono grants paths but never creates them, and this one cannot be created at
  # activation time: the ambient branch is only known at run time, and nothing
  # may pre-create a path under /run/user/$UID either -- the home-manager
  # activation service runs at boot, before logind creates that directory, and
  # logind's later tmpfs mount would hide anything put there.
  #
  # `tmpLeaf` defaults to the command; pi-claude-login runs `claude` in pi's
  # profile and sets it to "pi", so it shares pi's TMPDIR rather than
  # claude-local's.
  #
  # `wrapper` is the argv between `exec` and `nono`. mkNonoAlias passes none:
  # that is the nono-only string, which `<alias>_nono` must equal.
  mkNonoAliasWith = wrapper: {
    command,
    profile,
    extraArgs ? [],
    tmpLeaf ? command,
  }: let
    tmpdir = sandboxTmpdirExpr tmpLeaf;
    inner =
      lib.concatStringsSep " "
      (["mkdir" "-p" "-m" "700" "\"$TMPDIR\"" "&&" "exec"]
        ++ wrapper
        ++ ["nono" "run" "--profile" profile]
        ++ scfg.nonoArgs
        ++ extraArgs
        ++ ["--" command "\"$@\""]);
  in "TMPDIR=\"${tmpdir}\" sh -c '${inner}' ${command}";

  mkNonoAlias = mkNonoAliasWith [];

  # The alias through the namespace isolation: `exec ai-sandbox-run
  # ... -- nono run ...` keeps the one-process, one-pipeline-element shape.
  # `alias` names the nono-only twin for the wrapper's fail-closed hint (null
  # for pi-claude-login, which has none); `x11` binds the host's X11 socket
  # dir into the private /tmp (display GPU twins). `--open-urls-profile` is
  # the profile whose open_urls the URL relay enforces.
  mkAlias = {
    alias ? null,
    x11 ? false,
    ...
  } @ a: let
    base = builtins.removeAttrs a ["alias" "x11"];
    wrapper =
      ["ai-sandbox-run"]
      ++ lib.optional x11 "--x11"
      ++ lib.optionals (alias != null) ["--nono-alias" "${alias}_nono"]
      ++ ["--open-urls-profile" a.profile "--"];
  in
    if isolationEnabled
    then mkNonoAliasWith wrapper base
    else mkNonoAlias base;

  # Services get a profile but no alias: a service command is usually a management CLI of its
  # own, and an alias that shadowed it would send `<service> status` into a
  # non-interactive sandbox with no cwd grant.
  sandboxAliases = lib.mapAttrs (command: profile:
    mkAlias {
      alias = command;
      inherit command profile;
    })
  scfg.harnessProfiles;

  # `x11` follows the variant: only one granted the X11 cookie gets the host's X11 socket dir
  # inside its private /tmp. TMPDIR is keyed on the harness's command, so `claude_gpu` shares
  # claude's scratch dir; the isolation that matters (XDG_RUNTIME_DIR) is keyed on the profile.
  variantAliases = lib.mapAttrs (alias: e:
    mkAlias {
      inherit alias;
      inherit (e) command profile;
      extraArgs = e.spec.nonoArgs;
      x11 = e.spec.x11;
    })
  scfg.internal.variants;

  # `<alias>_nono`: every generated alias through nono only, i.e. the alias as
  # it was before the namespace isolation. Emitted only while
  # the isolation is on; with it off the alias itself is this string.
  nonoAliases =
    lib.mapAttrs' (command: profile:
      lib.nameValuePair "${command}_nono" (mkNonoAlias {inherit command profile;}))
    scfg.harnessProfiles
    // lib.mapAttrs' (alias: e:
      lib.nameValuePair "${alias}_nono" (mkNonoAlias {
        inherit (e) command profile;
        extraArgs = e.spec.nonoArgs;
      }))
    scfg.internal.variants;

  bogusGpu = lib.filterAttrs (_: c: !(scfg.harnesses ? ${c})) scfg.gpu.variants;
  unknownVariants = lib.attrNames (lib.filterAttrs (a: v: !(scfg.harnesses ? ${v.harness}) && !(bogusGpu ? ${a})) scfg.variants);

  # The fallback guard compares the path, not its spelling: `/tmp/`, `//tmp` and `/tmp/.` all
  # name /tmp (`/tmp//claude/tmp`). Empty and `.` segments are dropped before the comparison;
  # a `..` segment cannot be resolved without the filesystem, so it is refused outright.
  fallbackSegments = lib.filter (s: s != "" && s != ".") (lib.splitString "/" scfg.tmpdirFallback);
  fallbackPath = "/" + lib.concatStringsSep "/" fallbackSegments;
in {
  options.programs.aiSandbox.render.command = lib.mkOption {
    type = with lib.types; functionTo str;
    readOnly = true;
    description = ''
      Renders a sandboxed command line: `{command, profile, tmpLeaf ? command, extraArgs ? [],
      alias ? null, x11 ? false}` to the string an alias holds (through the namespace isolation
      while it is on, nono only otherwise). For consumers such as a login helper that runs a
      harness in another harness's profile.
    '';
  };

  config = {
    programs.aiSandbox.render.command = mkAlias;

    assertions = [
      {
        # A variant of a DISABLED harness is dropped silently (switching a harness off removes
        # its twins); one naming no harness at all is a mistake.
        assertion = lib.all (c: scfg.harnesses ? ${c}) (lib.attrValues scfg.gpu.variants);
        message = let
          unknown = lib.filter (c: !(scfg.harnesses ? ${c})) (lib.attrValues scfg.gpu.variants);
        in ''
          ai-sandbox: programs.aiSandbox.gpu.variants names command(s) with no entry
          in programs.aiSandbox.harnesses: ${lib.concatStringsSep ", " unknown}.
          A variant value must be a key of harnesses, not a profile name.
        '';
      }
      {
        # Every variant must be layered on a harness (switching a harness OFF drops its variants
        # silently, as above; naming none at all is a mistake). A bogus gpu.variants entry is
        # reported once, by the assertion above, not again through the variant it generates.
        assertion = unknownVariants == [];
        message = let
          unknown = unknownVariants;
        in ''
          ai-sandbox: programs.aiSandbox.variants names a harness that does not exist for:
          ${lib.concatStringsSep ", " unknown}. `harness` must be a key of programs.aiSandbox.harnesses.
        '';
      }
      {
        assertion =
          lib.hasPrefix "/" scfg.tmpdirFallback
          && !(lib.elem ".." fallbackSegments)
          && !(lib.elem fallbackPath [
            "/"
            "/tmp"
            "/var/tmp"
            "/run/lock"
            "/dev/shm"
            "/run/user"
          ]);
        message = ''
          ai-sandbox: programs.aiSandbox.tmpdirFallback must be an absolute path and
          must not be a shared root (/, /tmp, /var/tmp, /run/lock, /dev/shm or
          /run/user), however it is spelled (trailing, repeated or `.` segments),
          nor contain a `..` segment (got: ${scfg.tmpdirFallback}).

          mkdir -p neither chmods nor verifies a directory that already exists,
          so a shared root lets another local process pre-create the
          intermediate <command> directory as a symlink, and nono follows
          symlinks when it takes a grant. Use a 0700 directory you own.
        '';
      }
    ];

    # mkDefault so shell-specific modules (the terminal kit's zsh) can still
    # override individual aliases.
    home.shellAliases =
      lib.mapAttrs (_: lib.mkDefault)
      ((lib.optionalAttrs scfg.enable sandboxAliases)
        // (lib.optionalAttrs scfg.enable variantAliases)
        // (lib.optionalAttrs isolationEnabled nonoAliases)
        // scfg.extraAliases);
  };
}
