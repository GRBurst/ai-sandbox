# The pure nono profile emitter: arguments in, one profile attrset out (the caller renders
# it with `builtins.toJSON`, as `.text`, so evaluation-time checks can `fromJSON` it
# without import-from-derivation). No host knowledge: everything the host decides arrives
# as an argument (`deny`, `mediation`, `editor`).
{lib}: {
  name,
  pack,
  exclude ? [],
  include ? [],
  allow ? [],
  allowFile ? [],
  read ? [],
  readFile ? [],
  setVars ? {},
  denyVars ? [],
  allowGpu ? false,
  # Paths the profile denies (defence in depth, see the caller's reasons); always emitted.
  deny ? [],
  # Service-profile delta. Defaults to "omit the key entirely" so the interactive CLI
  # profiles keep exactly the JSON they had before this argument existed.
  listenPorts ? [],
  # nono's pathname AF_UNIX mediation, emitted only when on: extra connect+bind
  # subtrees beyond $TMPDIR, and connect-only socket dirs.
  mediation ? false,
  unixSocketSubtreeBind ? [],
  unixSocketDirs ? [],
  # null = no editor grants; otherwise the editor's own state and cache dirs are granted,
  # its XDG_RUNTIME_DIR is redirected to one dir PER PROFILE under its state dir (a shared
  # dir would be an agent-to-agent channel through nvim's listen socket), and its
  # `readFile` (e.g. a theme mode file) is read-only.
  editor ? null,
}: let
  editorOn = editor != null;
  appName =
    (
      if editorOn
      then editor
      else {}
    ).appName or "nvf";
  nvfRunDir = "$XDG_STATE_HOME/${appName}/run-${name}";

  # When on, exactly the socket inventory: the Nix daemon and nscd (connect), everything
  # below $TMPDIR and the editor runtime dir (connect+bind).
  mediationTop = lib.optionalAttrs mediation {linux.af_unix_mediation = "pathname";};
  mediationFs = lib.optionalAttrs mediation ({
      unix_socket = ["/nix/var/nix/daemon-socket/socket" "/run/nscd/socket"];
      unix_socket_subtree_bind =
        ["$TMPDIR"]
        ++ lib.optional editorOn nvfRunDir
        ++ unixSocketSubtreeBind;
    }
    // lib.optionalAttrs (unixSocketDirs != []) {unix_socket_dir = unixSocketDirs;});

  readFiles = lib.optionals editorOn (editor.readFile or []) ++ readFile;

  # nono expands $XDG_* in set_vars values. XDG_RUNTIME_DIR is editor-gated; the other
  # vars are not.
  envVars =
    setVars
    // lib.optionalAttrs editorOn {XDG_RUNTIME_DIR = nvfRunDir;};

  environment =
    lib.optionalAttrs (envVars != {}) {set_vars = envVars;}
    // lib.optionalAttrs (denyVars != []) {deny_vars = denyVars;};
in
  {
    "$schema" = "https://nono.sh/schemas/nono-profile.schema.json";

    # Exactly one base. nono's `extends` only ever ADDS: the schema has no mechanism to
    # remove an inherited filesystem path, and on Linux Landlock is strictly allow-list,
    # so `filesystem.deny` cannot claw one back either. A second base is therefore
    # permanent -- this single-element list IS the isolation boundary between the agents.
    extends = [pack];

    meta = {inherit name;};

    # exclude: inherited from the packs and unrelated to what the agent needs.
    # include: for packs whose own group list is incomplete on NixOS; emitted only when
    # non-empty, so pack-complete profiles keep exactly the JSON they always had.
    groups =
      {inherit exclude;}
      // lib.optionalAttrs (include != []) {inherit include;};

    filesystem =
      {
        allow =
          allow
          ++ lib.optionals editorOn ["$XDG_STATE_HOME/${appName}" "$XDG_CACHE_HOME/${appName}"];
        allow_file = allowFile;
        inherit deny;
      }
      // lib.optionalAttrs (read != []) {inherit read;}
      // lib.optionalAttrs (readFiles != []) {read_file = readFiles;}
      // mediationFs;
  }
  // mediationTop
  // lib.optionalAttrs (environment != {}) {inherit environment;}
  // lib.optionalAttrs allowGpu {
    # nono fails closed: `--allow-gpu` on the command line is refused unless the resolved
    # profile also opts in here, and this key alone grants nothing without the flag.
    allow_gpu = true;
  }
  // lib.optionalAttrs (listenPorts != []) {
    # The packs ship `network.listen_port = []`; declaring the port makes the capability
    # explicit and assertable instead of dependent on an upstream default.
    network.listen_port = listenPorts;
  }
# NO `interactive` key, deliberately: nono 0.78.0 rejects it as an unknown field.

