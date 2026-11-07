# What the module does to the home itself: installs nono, the isolation wrapper and the harnesses'
# own packages (`harnesses.<n>.package`, when set), sets `NONO_AUTO_MIGRATE` (bare profile names only;
# the packs the profiles extend are pulled by hand, see the README), and creates the directories nono
# grants but never creates (the per-harness cache dirs, the per-profile editor runtime dirs).
{
  config,
  lib,
  ...
}: let
  scfg = config.programs.aiSandbox;
  homeDir = config.home.homeDirectory;
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
in {
  options.programs.aiSandbox.internal.activationDirs = lib.mkOption {
    type = with lib.types; listOf str;
    internal = true;
    readOnly = true;
    description = "The absolute directories activation creates (0700): every managed command's cache dir and, with the editor grants, every profile's runtime dir. Empty while the module is off.";
  };

  config = lib.mkMerge [
    {
      programs.aiSandbox.internal.activationDirs =
        lib.optionals scfg.enable (map sandboxCacheDirAbs scfg.internal.managedCommands
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
      home.activation.aiSandboxDirs =
        lib.hm.dag.entryAfter ["writeBoundary"]
        (lib.concatMapStringsSep "\n"
          (d: ''run install -d -m 0700 "${d}"'')
          scfg.internal.activationDirs);
    })
  ];
}
