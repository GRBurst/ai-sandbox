# What the module does to the home itself: installs nono, the isolation wrapper and the harnesses'
# own packages (`harnesses.<n>.package`, when set), sets `NONO_AUTO_MIGRATE` (bare profile names only;
# the packs the profiles extend are pulled by hand, see the README), and creates the directories nono
# grants but never creates (the per-harness cache dirs, the per-profile editor runtime dirs).
{
  config,
  lib,
  pkgs,
  ...
}: let
  scfg = config.programs.aiSandbox;
  homeDir = config.home.homeDirectory;
  packPins = (import ./packs.nix {inherit lib;} (builtins.readFile ../../scripts/packs)).pins;
  editorEnabled = scfg.enable && scfg.editor.enable;
  isolationEnabled = scfg.enable && scfg.isolation.enable;

  # The real $XDG_RUNTIME_DIR holds gnome-keyring's secrets+ssh sockets and the
  # D-Bus session bus (a desktop session typically starts the daemon with
  # --components=pkcs11,secrets,ssh), so granting it would undo the profile's
  # own deny_credentials. Redirect instead: nvim's server socket and fzf-lua's
  # serverstart() only need *a* writable dir.
  #
  # One dir PER PROFILE, never shared: nvim's listen socket lands here, and
  # `nvim --server <sock> --remote-expr 'luaeval(...)'` executes arbitrary Lua
  # in a live editor. A shared dir would make that an agent-to-agent channel.
  #
  # It lives under nvim's own state dir, which the grant below already covers,
  # so the redirect costs no extra capability. Do NOT move it under
  # ~/.local/state/nono: nono refuses to grant any path overlapping its own
  # protected state root and the sandbox then fails to initialise.
  sandboxRuntimeDir = profile: "${homeDir}/.local/state/${scfg.editor.appName}/run-${profile}";

  # The persistent per-CLI cache root. Two spellings are unavoidable: activation
  # needs an absolute path, and the profile needs the $XDG_CACHE_HOME form
  # because nono expands that at profile-resolution time. Both derive from
  # xdg.cacheHome / $XDG_CACHE_HOME so they cannot drift, and
  # the checks assert they denote the same directory.
  #
  # Granted read+write for every CLI rather than patched for pi: the packs are
  # unpinned, so relying on the default profile's group:system_write_linux --
  # which is WRITE-ONLY -- for half the capability leaves it hostage to
  # upstream. That was a real bug: jiti
  # transpiled each pi extension, wrote the .mjs, then was denied reading it
  # back, and every extension failed to load with EACCES on its own cache file.
  sandboxCacheDirAbs = command: "${config.xdg.cacheHome}/${command}";

  # A base's own dir (`$HOME/...`, as the profile grants it), absolute.
  baseDirAbs = d:
    assert lib.assertMsg (lib.hasPrefix "$HOME/" d) "ai-sandbox: a base's dir must be under $HOME: ${d}";
      homeDir + lib.removePrefix "$HOME" d;
in {
  options.programs.aiSandbox.internal.activationDirs = lib.mkOption {
    type = with lib.types; listOf str;
    internal = true;
    readOnly = true;
    description = "The absolute directories activation creates (0700): every managed command's cache dir, the dirs of the emitted bases (a config dir of their harness's own) and, with the editor grants, every profile's runtime dir. Empty while the module is off.";
  };

  config = lib.mkMerge [
    {
      programs.aiSandbox.internal.activationDirs = lib.optionals scfg.enable (map sandboxCacheDirAbs scfg.internal.managedCommands
        ++ map baseDirAbs scfg.internal.baseDirs
        ++ lib.optionals editorEnabled (map sandboxRuntimeDir scfg.internal.profileNames));
    }

    (lib.mkIf scfg.enable {
      home.packages =
        [scfg.package]
        ++ lib.optional isolationEnabled scfg.runPackage
        ++ lib.concatMap (h: lib.optional (h.enable && h.package != null) h.package) (lib.attrValues scfg.harnesses);

      home.sessionVariables = lib.optionalAttrs scfg.autoInstallPacks {NONO_AUTO_MIGRATE = "1";};

      # nono grants paths but never creates them, and nvim will not mkdir its own
      # $XDG_RUNTIME_DIR. The per-CLI cache dirs are not editor-gated -- they hold
      # the persistent state that was moved out of TMPDIR.
      #
      # The private TMPDIRs are deliberately absent: the alias creates them,
      # because the ambient branch is only known at run time and because
      # nothing can pre-create a path under /run/user/$UID here anyway.
      #
      # The per-CLI cache dirs must be pre-created: nono cannot canonicalise a
      # path that does not exist, so it silently drops the grant -- which is
      # exactly how jiti's EACCES happened the first time.
      #
      # `install -d -m 0700`, not `mkdir -p -m 0700`. mkdir applies the mode
      # only to directories it CREATES; one that already exists keeps whatever
      # mode it had, so activation claimed 0700 while every ~/.cache/<cli> sat
      # at 0755. install chmods the named directory as well, and only the
      # named one -- a missing leading component such as ~/.cache is created
      # but not re-moded, so this cannot tighten a shared parent by accident.
      # That is also why the ALIAS still uses mkdir: there the parent may be a
      # project's own temp dir, which must not be re-moded.
      #
      # The mode matters here: these dirs hold the transpiled .mjs that the
      # harness then executes, so a world-readable cache is a cross-user
      # hand-off of executable code.
      # A base's dir that is a symlink is refused before anything is written: nono resolves
      # the link when it takes the grant, so a `~/.claude-sandbox -> ~/.claude` would hand
      # ~/.claude to every claude session (install.sh refuses it too).
      home.activation.aiSandboxBaseDirs =
        lib.hm.dag.entryBefore ["writeBoundary"]
        (lib.concatMapStringsSep "\n"
          (d: ''
            if [ -L "${d}" ]; then
              errorEcho "ai-sandbox: ${d} is a symbolic link; make it a directory of its own (copy what you need into it, never link it): the sandbox would get read and write on the link's target"
              exit 1
            fi'')
          (map baseDirAbs scfg.internal.baseDirs));

      home.activation.aiSandboxDirs =
        lib.hm.dag.entryAfter ["writeBoundary"]
        (lib.concatMapStringsSep "\n"
          (d: ''run install -d -m 0700 "${d}"'')
          scfg.internal.activationDirs);

      # nono does not fetch a pack a profile names in `extends`, so a missing or other-version pack
      # breaks that agent's runs until `nono pull` names it. This only names the line (offline:
      # one `nono list`, no pull, never a failed activation); scripts/packs is the pin. A listing
      # that cannot be read (nono missing, failing, hanging, other output) is one warning that
      # names every line, not one "missing" per pack.
      home.activation.aiSandboxPacks = let
        q = lib.escapeShellArg;
        refOf = p: let
          pin = packPins.${p} or null;
        in
          if pin == null
          then p
          else "${p}@${pin}";
        indent = s: "  " + builtins.replaceStrings ["\n"] ["\n  "] s;
        # one pack of a readable listing: absent, or at another version than the pin
        packCheck = p: let
          pin = packPins.${p} or null;
        in
          lib.concatStringsSep "\n" ([
              "_aiV=$(${pkgs.jq}/bin/jq -er --arg p ${q p} '.packages[$p].version // empty' <<<\"$_aiPacks\" 2>/dev/null) || _aiV="
              "if [ -z \"$_aiV\" ]; then"
              "  warnEcho ${q "ai-sandbox: nono lacks the pack ${p}; its sandboxed profiles fail until: nono pull ${refOf p}"}"
            ]
            ++ lib.optionals (pin != null) [
              "elif [ \"$_aiV\" != ${q pin} ]; then"
              "  warnEcho \"ai-sandbox: the nono pack ${p} is at \$_aiV, not at ${pin} as scripts/packs pins; left as it is\""
            ]
            ++ ["fi"]);
        pulls = lib.concatMapStringsSep "; " (p: "nono pull ${refOf p}") scfg.internal.requiredPacks;
      in
        lib.hm.dag.entryAfter ["writeBoundary"] ''
          _aiErr=$(${pkgs.coreutils}/bin/mktemp) || _aiErr=/dev/null
          _aiRc=0
          _aiPacks=$(${pkgs.coreutils}/bin/timeout 10 ${scfg.package}/bin/nono list --installed --json </dev/null 2>"$_aiErr") || _aiRc=$?
          _aiWhy=
          if [ "$_aiRc" = 124 ]; then
            _aiWhy="nono list timed out"
          elif [ "$_aiRc" != 0 ]; then
            _aiWhy="nono list exited $_aiRc: $(head -n 1 "$_aiErr" 2>/dev/null)"
          elif ! ${pkgs.jq}/bin/jq -e '(.packages // {}) | type == "object"' <<<"$_aiPacks" >/dev/null 2>&1; then
            _aiWhy="nono list printed no pack list this module understands"
          fi
          [ "$_aiErr" = /dev/null ] || rm -f "$_aiErr"
          if [ -n "$_aiWhy" ]; then
            warnEcho "ai-sandbox: cannot read nono's pack list ($_aiWhy); check that the packs are there: "${q pulls}
          else
          ${lib.concatMapStringsSep "\n" (p: indent (packCheck p)) scfg.internal.requiredPacks}
          fi
        '';
    })
  ];
}
