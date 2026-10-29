# The nono profile files: the profile arguments of every harness and service, their variants
# (the GPU twins are the `gpu` preset of variants.nix), the files under
# `xdg.configFile."nono/profiles"`, and the reclaim of the files nono rewrites in place.
# The profile body itself is the pure emitter ./profile.nix.
{
  config,
  lib,
  ...
}: let
  scfg = config.programs.aiSandbox;
  editorEnabled = scfg.enable && scfg.editor.enable;
  sharedSkillsDir = scfg.sharedSkillsDir;

  # ~/.local/share/nvf is deliberately absent: mnw is declarative and nothing
  # writes there. Add it only if a real failure names it.
  #
  # Profiles are emitted as `.text = builtins.toJSON ...` on purpose:
  # the checks parse them with builtins.fromJSON, which needs a
  # literal string. Switching the emitter to pkgs.formats.json would make them
  # `.source` -- a derivation path -- and every profile assertion would then
  # require import-from-derivation.
  # The emitter is pure (./profile.nix); what the host decides is passed in:
  # the zsh paths to deny, the mediation switch, and the editor grants with the darkman
  # mode file (read-only, single file; silently falls back to light).
  emitProfile = import ./profile.nix {inherit lib;};
  mkProfile = args:
    emitProfile ({
        mediation = scfg.unixMediation.enable;
        editor =
          if editorEnabled
          then {inherit (scfg.editor) appName readFile;}
          else null;
      }
      // args
      // (let
        d = scfg.profileDefaults;
      in {
        deny = d.deny ++ (args.deny or []);
        allow = (args.allow or []) ++ d.allow;
        read = (args.read or []) ++ d.read;
        readFile = (args.readFile or []) ++ d.readFile;
      }));

  # NO `interactive` key here, deliberately. nono carried one until 0.77.x, but
  # only as `deprecated: true` -- "Parsed for backward compatibility but
  # ignored. Supervised mode preserves TTY by default." -- so for every version
  # this repo has ever pinned it changed nothing. 0.78.0 dropped the compat
  # parse, and because nono rejects unknown profile fields the dead key stopped
  # being a no-op and became `Profile parse error: unknown field 'interactive'`,
  # i.e. exit 1 before the agent starts. There is no successor key; the
  # behaviour it named is now unconditional.

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
  sandboxCacheDir = command: "$XDG_CACHE_HOME/${command}";

  # TMPDIR used to double as a cache root, which is what blocked moving it into
  # RAM. Two consumers wrote *persistent* state there:
  #
  #   jiti -> {TMPDIR}/jiti                (fsCache, env JITI_FS_CACHE)
  #   node -> {TMPDIR}/node-compile-cache  (env NODE_COMPILE_CACHE)
  #
  # One home counted 36 orphaned .mjs and 403
  # orphaned node-compile-cache entries under the old ~/.cache/pi/tmp. Left
  # alone, a tmpfs TMPDIR would make pi re-transpile every extension and every
  # harness rebuild its V8 compile cache once per session.
  #
  # In the PROFILE, not the alias: both are read only inside the sandbox, the
  # same reason XDG_RUNTIME_DIR lives there. nono expands $XDG_CACHE_HOME in
  # set_vars values, and neither key is reserved -- only PATH and NONO_* are.
  sandboxCacheVars = command: {
    JITI_FS_CACHE = "${sandboxCacheDir command}/jiti";
    NODE_COMPILE_CACHE = "${sandboxCacheDir command}/node-compile-cache";
  };

  # Stripped so the harnesses copy through the TERMINAL (OSC 52) instead of
  # wl-copy/xclip. The display sockets are unusable in here anyway -- the
  # Wayland one sits under the real XDG_RUNTIME_DIR, which the isolation
  # hides, and /tmp/.X11-unix is not in the private /tmp (display GPU twins
  # excepted) -- but while the variables are set pi picks wl-copy, fails, and
  # never falls back: its copyToClipboard emits OSC 52 only when it sees no
  # display at all.
  #
  # OSC 52 is what makes this user-only. The sequence goes to the harness's own
  # stdout; the agent's tool subprocesses have no controlling tty (/dev/tty ->
  # ENXIO), so they cannot emit one; with the terminal limited to OSC 52 copy
  # (Alacritty: OnlyCopy), nothing can read the clipboard back that way.
  # Paste stays the terminal's own Ctrl+Shift+V.
  #
  # Not the boundary itself: Landlock below ABI 9 does not mediate connect() on
  # pathname UNIX sockets, so nono alone leaves them reachable by absolute path.
  # The namespace isolation (ai-sandbox-run, `session` layer) is what hides
  # them; under an `<alias>_nono` twin or AI_SANDBOX_RELAX=session they are
  # reachable again. This only makes the harness choose the channel that works.
  sandboxDisplayVars = ["WAYLAND_DISPLAY" "DISPLAY"];

  # The profile arguments of a harness, from its options (./harnesses.nix); the
  # shared skills dir is added for the harnesses that scan it and whose pack does not grant it.
  harnessSpec = h: {
    inherit (h) pack include exclude allow allowFile readFile setVars deny unixSocketSubtreeBind denyVars;
    read = h.read ++ lib.optional h.readsSharedSkills sharedSkillsDir;
  };

  # The enabled services (./services.nix): their profile is named after the service and may
  # bind exactly the backend port.
  services = lib.filterAttrs (_: s: s.enable) scfg.services;
  serviceSpecs = lib.mapAttrs (_: s: harnessSpec s.profile // {listenPorts = [s.backendPort];}) services;

  # The harnesses and the services.
  sandboxSpecs = lib.mapAttrs (_: harnessSpec) scfg.harnesses // serviceSpecs;

  # Aliased CLIs and unaliased services share the profile emitter, the cache
  # dirs and the reclaim step; only the alias generation is keyed on
  # `programs.aiSandbox.harnessProfiles` alone.
  allSandboxProfiles = scfg.harnessProfiles // lib.mapAttrs (n: _: n) services;

  managedCommands =
    lib.filter (c: allSandboxProfiles ? ${c}) (lib.attrNames sandboxSpecs);

  baseProfileName = command: allSandboxProfiles.${command};

  # The TMPDIR grant, the cache grant and the cache-var pins are added here
  # rather than in each spec so they cannot be forgotten for a CLI added later,
  # and so the GPU twins inherit them.
  #
  # `$TMPDIR` rather than a literal path: nono expands it from the inherited
  # environment, so the grant follows whatever the alias exported -- ambient or
  # fallback -- and there is no second hardcoded path to drift. Safe only
  # because the alias builder (./aliases.nix) appends a per-command leaf to the
  # TMPDIR it exports; that leaf is what makes the grant safe for any ambient value.
  baseProfileArgs = command: let
    spec = sandboxSpecs.${command};
    # Per-pack defaults reach every profile of the pack -- CLI, service, GPU twin.
    pack = scfg.packDefaults.${spec.pack} or {};
  in
    spec
    // {
      name = baseProfileName command;
      allow = (spec.allow or []) ++ (pack.allow or []) ++ ["$TMPDIR" (sandboxCacheDir command)];
      allowFile = (spec.allowFile or []) ++ (pack.allowFile or []);
      read = (spec.read or []) ++ (pack.read or []);
      readFile = (spec.readFile or []) ++ (pack.readFile or []);
      deny = (spec.deny or []) ++ (pack.deny or []);
      unixSocketSubtreeBind = (spec.unixSocketSubtreeBind or []) ++ (pack.unixSocketSubtreeBind or []);
      setVars = sandboxCacheVars command // (spec.setVars or {}) // (pack.setVars or {});
      denyVars = spec.denyVars or sandboxDisplayVars;
    };

  # A variant is its harness's profile plus a delta; with `allowGpu` and `x11` it is the GPU twin.
  # The profile extends the same single pack as its harness (a suffix, not a separate lineage),
  # so the isolation boundary is unchanged and only the delta differs.
  #
  # The GPU delta, and nothing else. /run/opengl-driver, /nix/store, /sys and
  # /dev/dri are deliberately absent: on NixOS /run/opengl-driver is a symlink
  # into /nix/store (already granted via group:nix_runtime), /sys comes from
  # group:linux_sysfs_read, and the render nodes come from --allow-gpu itself.
  #
  # /dev/input and /dev/snd are refused outright. The first is unconditional
  # global keylogging; the second is audio, not GPU.
  variantProfileArgs = entry: let
    base = baseProfileArgs entry.command;
    v = entry.spec;
  in
    base
    // {
      name = entry.profile;
      allowGpu = v.allowGpu;
      # XShm and dmabuf hand buffers between the client and the X server
      # through POSIX shared memory.
      allow = (base.allow or []) ++ v.allow ++ lib.optional v.x11 "/dev/shm";
      allowFile = (base.allowFile or []) ++ v.allowFile;
      # libudev enumerates DRM devices through /run/udev; without it Vulkan and
      # EGL loaders fall back to no device at all.
      read = (base.read or []) ++ v.read ++ lib.optional v.allowGpu "/run/udev";
      # The X11 magic cookie. read_file, never a write grant: a writable
      # cookie would let the sandboxed agent authorise further clients.
      readFile = (base.readFile or []) ++ v.readFile ++ lib.optional v.x11 "$HOME/.Xauthority";
      setVars = (base.setVars or {}) // v.setVars;
      deny = (base.deny or []) ++ v.deny;
      unixSocketSubtreeBind = (base.unixSocketSubtreeBind or []) ++ v.unixSocketSubtreeBind;
    }
    // lib.optionalAttrs v.x11 {
      # Under mediation: connect to the X server's socket.
      unixSocketDirs = ["/tmp/.X11-unix"];
      # A windowed app needs DISPLAY to find the X server granted above. Only
      # DISPLAY: the Wayland socket is not part of this delta.
      denyVars = lib.remove "DISPLAY" base.denyVars;
    };

  # One profile per (harness, suffix): variants sharing both share the profile (the first wins).
  variantEntries =
    lib.attrValues
    (lib.listToAttrs (map (e: lib.nameValuePair e.profile e) (lib.attrValues scfg.internal.variants)));

  allProfileNames =
    lib.attrValues allSandboxProfiles
    ++ map (e: e.profile) variantEntries;

  nonoProfileTargets =
    map (n: "${config.xdg.configHome}/nono/profiles/${n}.json")
    allProfileNames;
in {
  options.programs.aiSandbox.internal = {
    managedCommands = lib.mkOption {
      type = with lib.types; listOf str;
      internal = true;
      readOnly = true;
      description = "The commands that get a profile file and a private cache dir (harnesses and services).";
    };
    profileNames = lib.mkOption {
      type = with lib.types; listOf str;
      internal = true;
      readOnly = true;
      description = "Every emitted nono profile name: harnesses, services and variants.";
    };
  };

  config = lib.mkMerge [
    {
      programs.aiSandbox.internal = {
        inherit managedCommands;
        profileNames = allProfileNames;
      };
    }

    (lib.mkIf scfg.enable {
      # Bodies come from sandboxSpecs above; this only decides which files exist.
      xdg.configFile = let
        mkEntry = args: {
          name = "nono/profiles/${args.name}.json";
          value.text = builtins.toJSON (mkProfile args);
        };
      in
        lib.listToAttrs
        (map (c: mkEntry (baseProfileArgs c)) managedCommands
          ++ map (e: mkEntry (variantProfileArgs e)) variantEntries);

      # nono rewrites these in place through its save-profile path -- the
      # serialize-roundtrip it leaves behind is a regular file, which aborts
      # the next switch on HM's clobber check. Discarding nono's version is
      # intended: the Nix source is the owner, and warnEcho makes
      # the discard visible rather than silent.
      home.activation.nonoProfileReclaim = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
        for f in ${lib.escapeShellArgs nonoProfileTargets}; do
          if [ -e "$f" ] && [ ! -L "$f" ]; then
            warnEcho "nono rewrote $f; restoring the Home Manager profile"
            run rm -f "$f"
          fi
        done
      '';
    })
  ];
}
