# Fixtures and helpers of the module checks: the
# sandbox module alone (bare nixpkgs, no overlay, no flake inputs). `package` is a
# stub (the consumer brings the real nono). `module` and `nixosModule` are the modules under
# test (every check file takes them from here).
{
  pkgs,
  lib,
  home-manager,
}: rec {
  module = ../../modules/home-manager;
  nixosModule = ../../modules/nixos;

  fixtureBase = {
    home.username = "ai-test";
    home.homeDirectory = "/tmp/ai-test";
    home.stateVersion = "25.11";
    programs.aiSandbox = {
      enable = lib.mkDefault true;
      package = lib.mkDefault pkgs.hello;
    };
  };

  # The module plus one override. Every fixture below is this with a different `extra`.
  aiFixtureWith = extra:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [module fixtureBase extra];
    };

  # `homeManagerConfiguration` turns a failed module assertion into a THROW on any access to
  # `config`. The same module set evaluated the way Home Manager's own tests do it (plain
  # `evalModules` over modules/modules.nix) keeps `config.assertions` readable as data, so a
  # negative case names exactly which assertions fail, with their messages.
  hmLib = import "${home-manager}/modules/lib/stdlib-extended.nix" lib;
  aiFailedWith = extra:
    map (a: a.message) (lib.filter (a: !a.assertion)
      (hmLib.evalModules {
        class = "homeManager";
        specialArgs.modulesPath = "${home-manager}/modules";
        modules =
          [module fixtureBase extra]
          ++ import "${home-manager}/modules/modules.nix" {
            inherit pkgs;
            lib = hmLib;
            check = true;
          };
      })
      .config
      .assertions);

  # The failed assertions are exactly one, and it starts with `prefix` (the module's
  # `ai-sandbox: ` prefix included).
  aiFailsWith = prefix: extra: let
    f = aiFailedWith extra;
  in
    lib.length f == 1 && lib.hasPrefix prefix (lib.head f);

  # One check of many assertions: the builder prints the message of the first one that
  # fails; the messages are also exposed through passthru.
  mkAssertionCheck = name: assertions:
    pkgs.runCommand name {passthru.messages = map (a: a.message) assertions;} ''
      ${lib.concatMapStringsSep "\n" (assertion: ''
          if [ "${
            if assertion.condition
            then "1"
            else "0"
          }" != "1" ]; then
            echo ${lib.escapeShellArg assertion.message} >&2
            exit 1
          fi
        '')
        assertions}
      touch "$out"
    '';

  # The module's defaults: no editor (the grants must not appear), isolation and GPU twins on.
  aiNoNvf = aiFixtureWith {};

  aiNoSandbox = aiFixtureWith {programs.aiSandbox.enable = false;};

  # The GPU twins must be a removable layer: turning them off has to leave the
  # base profiles and aliases byte-identical, so a GPU regression can always be
  # backed out with one switch.
  aiNoGpu = aiFixtureWith {programs.aiSandbox.gpu.enable = false;};

  # The per-user off switch of the isolation. Every alias must be
  # the nono-only string again, with no `_nono` twins and no wrapper installed.
  aiNoIsolation = aiFixtureWith {programs.aiSandbox.isolation.enable = false;};

  # Headless GPU twins: no display delta, so the wrapper must not bind the
  # host's X11 socket dir either.
  aiNoDisplay = aiFixtureWith {programs.aiSandbox.gpu.display = false;};

  # nono's own pathname AF_UNIX mediation, switched on, with one more harness whose
  # profile carries an extra socket grant (as a service profile does), so that grant is
  # observable.
  aiMediationModule = {
    programs.aiSandbox.unixMediation.enable = true;
    programs.aiSandbox.harnesses.svc = {
      profileName = "svc-test";
      pack = "nolabs-ai/claude";
      unixSocketSubtreeBind = ["$HOME/.svc"];
    };
  };
  aiMediation = aiFixtureWith aiMediationModule;

  # The same with the editor grants on.
  aiMediationNvf = aiFixtureWith {
    imports = [aiMediationModule];
    programs.aiSandbox.editor.enable = true;
  };

  # Every nono profile a configuration emits, parsed, keyed by profile name.
  # Derived from the files, not from a name list, so a profile added later is
  # covered.
  aiEmittedProfiles = h: let
    pre = "nono/profiles/";
  in
    lib.mapAttrs' (k: v:
      lib.nameValuePair (lib.removeSuffix ".json" (lib.removePrefix pre k))
      (builtins.fromJSON v.text))
    (lib.filterAttrs (k: _: lib.hasPrefix pre k) h.xdg.configFile);

  # The mediation delta of a profile: its `linux` key and every
  # `filesystem.unix_socket*` key.
  aiUnixSocketGrants = p: lib.filterAttrs (k: _: lib.hasPrefix "unix_socket" k) (p.filesystem or {});
  aiWithoutMediation = p:
    builtins.removeAttrs p ["linux"]
    // {filesystem = lib.filterAttrs (k: _: !(lib.hasPrefix "unix_socket" k)) p.filesystem;};

  # The socket grant set, restated literally: connect to the Nix daemon and nscd; connect+bind
  # below $TMPDIR (and the profile's nvf runtime dir with the editor grants).
  aiMediationSockets = ["/nix/var/nix/daemon-socket/socket" "/run/nscd/socket"];

  # Grants moved from CLI flags into the profile JSON, so the alias is now the
  # computed TMPDIR, the mkdir that creates it, the ai-sandbox-run prefix (see
  # aiWrapperArgv; absent from the `_nono` twins), the profile selection and
  # --allow-cwd.
  aiExpectedArgs = _: ["--allow-cwd"];

  # The SHELL EXPRESSION the alias must export, not a resolved path: a project
  # that sets its own TMPDIR must win, so the value is only known at run time.
  #
  # Must still be set BEFORE nono: the packs' `filesystem.allow` entry `$TMPDIR`
  # is expanded from the inherited environment at profile-resolution time.
  # Setting it via the profile's environment.set_vars would be too late.
  #
  # Restated literally rather than read back from the module: a silent change to
  # the fallback root -- or, far worse, to the per-command leaf -- has to fail
  # here. The leaf is the security property. It is what stops the profile's
  # `$TMPDIR` grant from ever denoting a shared directory: without it,
  # `nix develop` (which sets TMPDIR=/run/user/$UID, NixOS/nix#10430) would make
  # that grant resolve to the gnome-keyring/D-Bus socket dir, and an unset
  # TMPDIR would resolve it to all of /tmp including /tmp/.X11-unix.
  aiTmpdirFallback = "/run/user/$UID";
  aiTmpdirExpr = command: "\${TMPDIR:-${aiTmpdirFallback}}/${command}/tmp";

  # ONE command, deliberately not an `mkdir ... && nono ...` list: an `&&` list
  # would break `echo prompt | claude -p`, because the pipeline's second element
  # would be mkdir and nono would then inherit the terminal instead of the pipe.
  # `sh -c` keeps the alias a single pipeline element, `exec` keeps it a single
  # process, and `"$@"` receives the arguments the shell appends after an alias.
  #
  # `wrap` is the argv between `exec` and `nono`: the ai-sandbox-run prefix of
  # the namespace isolation, or [] for the nono-only string.
  #
  # A harness with a pre-start hook (`harnesses.<command>.preStart`) has its segment
  # (aiPreStartSegment) between the mkdir and the exec.
  aiAliasString = wrap: extra: h: command: profile: let
    inner =
      lib.concatStringsSep " "
      (["mkdir" "-p" "-m" "700" "\"$TMPDIR\"" "&&"]
        ++ lib.optional (aiPreStartSegment h command != "") (lib.removeSuffix " " (aiPreStartSegment h command))
        ++ ["exec"]
        ++ wrap
        ++ ["nono" "run" "--profile" profile]
        ++ aiExpectedArgs h
        ++ extra
        ++ ["--" command "\"$@\""]);
  in "TMPDIR=\"${aiTmpdirExpr command}\" sh -c '${inner}' ${command}";

  # The pre-start hook segment of the aliases of harness `command` ("" for none): the store file
  # sourced with stdin from /dev/null and stdout to stderr, its failure ignored.
  aiPreStartSegment = h: command: let
    f = h.programs.aiSandbox.internal.preStartFiles.${command} or null;
  in
    if f == null
    then ""
    else "{ . ${f} || :; } </dev/null >&2 && ";

  # An alias string without any hook segment of `h`: the shape rows hold for the rest.
  aiWithoutPreStart = h: a: let
    segs = map (c: aiPreStartSegment h c) (lib.attrNames h.programs.aiSandbox.internal.preStartFiles);
  in
    builtins.replaceStrings segs (map (_: "") segs) a;

  # The wrapper argv an alias puts in front of nono. `--nono-alias` names the
  # nono-only twin for the fail-closed hint; `--open-urls-profile`
  # is the profile whose open_urls the URL relay enforces.
  aiWrapperArgv = {
    alias,
    profile,
    x11 ? false,
  }:
    ["ai-sandbox-run"]
    ++ lib.optional x11 "--x11"
    ++ ["--nono-alias" "${alias}_nono" "--open-urls-profile" profile "--"];

  # The nono-only alias: the string every alias had before the namespace
  # isolation. `<alias>_nono` must equal it, and with
  # isolation.enable = false the alias itself must equal it again.
  aiExpectedNonoAlias = aiAliasString [] [];
  aiExpectedNonoGpuAlias = aiAliasString [] ["--allow-gpu"];

  # The generated alias names of a user: one per enabled harness, plus one
  # per variant of an enabled harness (the GPU twins are the preset that
  # generates two of them; an owner's own variants come with it).
  aiGeneratedAliases = h: let
    s = h.programs.aiSandbox;
  in
    lib.attrNames s.harnessProfiles ++ lib.attrNames s.internal.variants;

  # The generated aliases that have a nono-only twin `<alias>_nono`: all but the variants with
  # gitDirs, whose git dirs only the isolation binds read-only (nono alone would leave them
  # writable).
  aiTwinnedAliases = h: let
    s = h.programs.aiSandbox;
  in
    lib.attrNames s.harnessProfiles ++ lib.attrNames (lib.filterAttrs (_: v: v.spec.gitDirs == []) s.internal.variants);

  # Generated alias name -> its nono-only string, derived from the options of `h`: the harness's
  # command in the (variant's) profile, with the variant's own `nono` flags. null for a variant
  # with gitDirs (it has none), so a consumer comparing over aiGeneratedAliases fails its row
  # instead of throwing on a missing attribute.
  aiExpectedNonoAliases = h: let
    s = h.programs.aiSandbox;
  in
    lib.mapAttrs (c: p: aiExpectedNonoAlias h c p) s.harnessProfiles
    // lib.mapAttrs (_: v:
      if v.spec.gitDirs == []
      then aiAliasString [] v.spec.nonoArgs h v.command v.profile
      else null)
    s.internal.variants;

  # alias name -> the harness (key of `harnesses`) it borrows its spec from. Restated
  # literally rather than read back from the option: adding a GPU twin has to be
  # recorded here, because every isolation invariant below has to cover it.
  aiGpuVariants = {
    claude_gpu = "claude";
    opencode_gpu = "opencode";
  };

  aiExpectedAlias = h: command: profile:
    aiAliasString (aiWrapperArgv {
      alias = command;
      inherit profile;
    }) []
    h
    command
    profile;

  # nono fails CLOSED on a half-configured opt-in: with a profile selected, the
  # profile must carry `allow_gpu` or the run is refused, and the flag alone is
  # not enough. So the flag belongs on the alias and nowhere else -- putting it
  # in sandbox.args would arm it for every non-GPU profile too, which the
  # "GPU access must stay withheld" assertion below forbids.
  #
  # TMPDIR is keyed on the COMMAND, not the alias, so claude_gpu deliberately
  # shares claude's tmpdir: it holds scratch only, and the per-agent isolation
  # that matters is XDG_RUNTIME_DIR, which is keyed on the profile and therefore
  # still distinct.
  #
  # The alias NAME is an argument because the wrapper's fail-closed hint names
  # `<alias>_nono`, which differs from the command for a twin. `--x11`: a
  # configuration with gpu.display on gives the twin the X11 socket dir in
  # its private /tmp; the aiNoDisplay fixture pins the other branch.
  aiExpectedGpuAlias = h: alias: command: profile:
    aiAliasString (aiWrapperArgv {
      inherit alias profile;
      x11 = true;
    }) ["--allow-gpu"]
    h
    command
    profile;

  # `-local` vs `-claude` is not decoration: the suffix records whether the
  # profile reaches Claude Code's credentials. agy does not, so it is
  # `agy-local`.
  aiProfileNames = ["agy-local" "claude-local" "opencode-claude" "pi-claude"];

  aiGpuProfileNames = ["claude-local-gpu" "opencode-claude-gpu"];

  # `-gpu` is a suffix on the base profile name, so a twin's family -- its pack
  # and the dirs its CLI owns -- is recovered by
  # stripping it. Without this a twin would look "foreign" to its own base.
  aiBaseProfileOf = lib.removeSuffix "-gpu";

  aiAllProfileNames = aiProfileNames ++ aiGpuProfileNames;

  # profile -> its single registry pack (one pack per agent)
  aiPack = {
    agy-local = "nolabs-ai/antigravity";
    claude-local = "nolabs-ai/claude";
    opencode-claude = "nolabs-ai/opencode";
    pi-claude = "nolabs-ai/pi";
  };

  # ai-sandbox's own bases -> the registry pack each re-bases: the pack's profile without its
  # grants on the harness's own configuration (modules/home-manager/bases.nix). A base is
  # emitted while a profile of its pack is, and extends `default`, as the pack does.
  aiBasePack = {
    ai-sandbox-claude = "nolabs-ai/claude";
    ai-sandbox-opencode = "nolabs-ai/opencode";
  };

  # profile -> its single `extends` entry: its pack, or the ai-sandbox base of its pack.
  # Restated literally, like aiPack: a profile that extends its pack again has to fail here.
  aiBase =
    aiPack
    // {
      claude-local = "ai-sandbox-claude";
      opencode-claude = "ai-sandbox-opencode";
    };

  # IFD-free: this requires the profiles stay `.text = builtins.toJSON ...`.
  # Switching the emitter to pkgs.formats.json would make them `.source`, a
  # derivation path, and every assertion below would need import-from-derivation.
  aiProfile = h: n: builtins.fromJSON h.xdg.configFile."nono/profiles/${n}.json".text;
  aiProfiles = h: map (aiProfile h) aiProfileNames;

  aiAliasesOf = h:
    lib.attrValues
    (lib.filterAttrs
      (n: _: lib.elem n (lib.attrNames h.programs.aiSandbox.harnessProfiles))
      h.home.shellAliases);

  # The base aliases plus the GPU twins and every other variant. Every invariant on the
  # alias SHAPE -- as opposed to which profile it names -- has to hold for those too.
  aiAllAliasesOf = h:
    aiAliasesOf h
    ++ map (a: h.home.shellAliases.${a}) (lib.attrNames aiGpuVariants)
    ++ map (a: h.home.shellAliases.${a}) (lib.attrNames (removeAttrs h.programs.aiSandbox.internal.variants (lib.attrNames aiGpuVariants)));

  # The nono-only twins `<alias>_nono` of every twinned alias (aiTwinnedAliases).
  # `or ""`: a missing twin must fail the assertion that reads it, not abort
  # the whole check with a missing-attribute throw.
  aiNonoTwinsOf = h:
    map (a: h.home.shellAliases."${a}_nono" or "") (aiTwinnedAliases h);

  # Every alias an interactive user can type: the wrapped aliases and their
  # nono-only twins. The shape invariants that do not depend on the wrapper
  # (TMPDIR, `:-`, "$@") hold for both.
  aiEveryAliasOf = h: aiAllAliasesOf h ++ aiNonoTwinsOf h;
}
