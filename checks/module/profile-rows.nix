# Profile invariants as a row function: `{home}` -> assertions about
# one evaluated home (a fixture, or a real home). Messages are not
# prefixed with a home name: a consumer's own checks may combine the
# rows of several homes message by message, so a message is the same for every home.
# The helpers are those of ./lib.nix.
{
  lib,
  helpers,
}: let
  inherit
    (helpers)
    aiProfile
    aiBase
    aiBasePack
    aiAllProfileNames
    aiBaseProfileOf
    aiEmittedProfiles
    aiUnixSocketGrants
    aiGeneratedAliases
    aiTwinnedAliases
    aiExpectedNonoAliases
    aiExpectedAlias
    aiExpectedGpuAlias
    aiTmpdirExpr
    aiEveryAliasOf
    aiAllAliasesOf
    aiNonoTwinsOf
    ;
in
  {
    home,
    files ? true,
    aliases ? true,
  }: let
    # The profile files (what `profiles.nix` owns), then the aliases.
    fileRows = [
      {
        # (E) THE assertion. nono's `extends` is monotone-additive and the profile
        # schema has no mechanism to remove an inherited filesystem path, so a
        # second base is permanent. Everything below is a corollary of this.
        # The base is the profile's pack or, for a re-based pack, the ai-sandbox
        # base of it, which itself extends `default` only (as the pack does).
        condition =
          lib.all
          (n: (aiProfile home n).extends == [aiBase.${aiBaseProfileOf n}])
          aiAllProfileNames
          && lib.all (b: ((aiEmittedProfiles home).${b}.extends or null) == ["default"])
          (lib.filter (b: aiBasePack ? ${b}) (map (n: aiBase.${aiBaseProfileOf n}) aiAllProfileNames));
        message = "each nono profile must extend exactly its own base: its pack, or the ai-sandbox base of its pack (isolation invariant E)";
      }
      {
        # open_urls is replace-on-override, so a hand-written block is the
        # fingerprint of a second `extends` base. Its absence is a proxy alarm for
        # the one-pack rule regressing.
        condition = lib.all (n: !(aiProfile home n ? open_urls)) aiAllProfileNames;
        message = "no profile may override open_urls (would signal a second extends base)";
      }
      {
        # Mediation off: nono 0.78.0 denies granted sockets under mediation
        # (nolabs-ai/nono#1970, #1420), so by default no profile may
        # carry any part of it. The ai-sandbox bases are exempt: their socket
        # grants are the pack's own, byte for byte (the `bases` check), which the
        # profiles inherited from the pack before.
        condition = (h: let
          ps = lib.attrValues (removeAttrs (aiEmittedProfiles h) (lib.attrNames aiBasePack));
        in
          ps != [] && lib.all (p: !(p ? linux) && aiUnixSocketGrants p == {}) ps)
        home;
        message = "ai-mediation-off: no profile may carry linux.* or unix_socket* while unixMediation is off";
      }
    ];
    aliasRows = [
      {
        # Every generated alias -- base and GPU twin, both users --
        # runs nono inside the namespace isolation, and is exactly the
        # expected string, i.e. the nono-only string with the wrapper argv
        # inserted after `exec`. Derived from the options, so an alias added
        # later is covered without editing this list.
        condition = (h: let
          a = h.home.shellAliases;
          s = h.programs.aiSandbox;
          gpu = lib.optionals h.programs.aiSandbox.gpu.enable (lib.attrNames h.programs.aiSandbox.gpu.variants);
        in
          aiGeneratedAliases h
          != []
          && lib.all (n: lib.hasInfix " exec ai-sandbox-run " (a.${n} or "")) (aiGeneratedAliases h)
          && lib.all (c: a.${c} == aiExpectedAlias h c s.harnessProfiles.${c}) (lib.attrNames s.harnessProfiles)
          && lib.all (v: let
            c = h.programs.aiSandbox.gpu.variants.${v};
          in
            a.${v} == aiExpectedGpuAlias h v c "${s.harnessProfiles.${c}}-gpu")
          gpu)
        home;
        message = "ai-alias-wrapped: every generated alias must exec ai-sandbox-run before nono";
      }
      {
        # Each generated alias but a variant with gitDirs (aiTwinnedAliases) has a
        # twin `<alias>_nono` that is exactly its nono-only string -- the alias as
        # it was before the isolation -- and never reaches the wrapper. Set equality on the
        # `_nono` keys, so a missing twin and a stray one both fail.
        condition = (h: let
          a = h.home.shellAliases;
          want = map (n: "${n}_nono") (aiTwinnedAliases h);
          got = lib.filter (lib.hasSuffix "_nono") (lib.attrNames a);
        in
          lib.sort lib.lessThan got
          == lib.sort lib.lessThan want
          && lib.all (n: a."${n}_nono" == (aiExpectedNonoAliases h).${n}) (aiTwinnedAliases h)
          && lib.all (t: !(lib.hasInfix "ai-sandbox-run" t)) (aiNonoTwinsOf h))
        home;
        message = "ai-alias-nono-twins: every generated alias (but a variant with gitDirs) needs <alias>_nono equal to its nono-only string";
      }
      {
        # Without this the nolabs-ai/opencode pack resolves `$TMPDIR` to /tmp and
        # grants read+write on ALL of it -- reaching /tmp/claude-$UID, /tmp/jiti
        # and /tmp/.X11-unix. The grant is inherited and therefore unremovable, so
        # the only lever is what $TMPDIR expands to.
        condition =
          lib.all
          (c: lib.all (n: lib.hasPrefix "TMPDIR=\"${aiTmpdirExpr c}\" " (home.home.shellAliases.${n} or "")) [c "${c}_nono"])
          (lib.attrNames home.programs.aiSandbox.harnessProfiles);
        message = "every sandbox alias must set a private TMPDIR (neutralises the pack's $TMPDIR grant)";
      }
      {
        # THE invariant that pays for granting a bare `$TMPDIR` in the profile.
        # That grant follows whatever the alias exported, so the alias must never
        # export a value that could denote a shared directory. A per-command leaf
        # makes that unrepresentable: an unset TMPDIR, `nix develop`'s
        # /run/user/$UID (NixOS/nix#10430) and a project's own $PWD/.tmp all come
        # out as <root>/<command>/tmp.
        #
        # Asserted on the ALIAS rather than the profile because the alias is where
        # the value is actually decided; the profile's spelling never changes.
        condition = let
          aliases = home.home.shellAliases;
        in
          lib.all
          (c:
            lib.all (n:
              lib.hasPrefix "TMPDIR=\"\${TMPDIR:-/" (aliases.${n} or "")
              && lib.hasInfix "/${c}/tmp\" " (aliases.${n} or "")) [c "${c}_nono"])
          (lib.attrNames home.programs.aiSandbox.harnessProfiles);
        message = "every alias must export TMPDIR with an absolute fallback root and a per-command leaf";
      }
      {
        # `:-` and not `-`: an exported-but-empty TMPDIR must fall back too,
        # otherwise the profile's `$TMPDIR` grant resolves to "/<command>/tmp" at
        # the filesystem root.
        condition =
          lib.all (a: !(lib.hasInfix "\${TMPDIR-" a)) (aiEveryAliasOf home);
        message = "the TMPDIR fallback must use :- (unset OR empty), never -";
      }
      {
        # Pipeline safety. An `mkdir ... && nono ...` list at the top level of an
        # alias breaks `echo prompt | claude -p`: the pipeline's second element
        # would be mkdir, and nono would inherit the terminal instead of the pipe.
        # The alias must stay a single pipeline element, and it must forward "$@",
        # because the shell appends trailing arguments after the alias text.
        #
        # The wrapped aliases `exec` ai-sandbox-run, which execs bwrap, which
        # runs nono: still one process chain, still one pipeline element.
        condition =
          lib.all
          (a:
            lib.hasInfix "sh -c 'mkdir -p -m 700 \"$TMPDIR\" && exec ai-sandbox-run " a
            && lib.hasInfix " -- nono run --profile " a
            && lib.hasInfix "\"$@\"" a
            && !(lib.hasPrefix "mkdir" a))
          (aiAllAliasesOf home);
        message = "the sandbox alias must stay one command (sh -c ... exec ai-sandbox-run ... -- nono run) and forward \"$@\"";
      }
      {
        # The same pipeline shape for the nono-only twins, in the form every
        # alias had before the isolation.
        condition =
          lib.all
          (a:
            lib.hasInfix "sh -c 'mkdir -p -m 700 \"$TMPDIR\" && exec nono run" a
            && lib.hasInfix "\"$@\"" a
            && !(lib.hasPrefix "mkdir" a))
          (aiNonoTwinsOf home);
        message = "every <alias>_nono must stay one command (sh -c ... exec nono) and forward \"$@\"";
      }
      {
        # A shared value would put every agent back in one writable directory.
        condition = let
          ts = map aiTmpdirExpr (lib.attrNames home.programs.aiSandbox.harnessProfiles);
        in
          lib.length (lib.unique ts) == lib.length ts;
        message = "TMPDIR values must be pairwise distinct across the agent CLIs";
      }
    ];
  in
    lib.optionals files fileRows ++ lib.optionals aliases aliasRows
