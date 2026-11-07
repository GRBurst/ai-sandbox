# The module checks: rows over the
# standalone fixtures of ./lib.nix only; wired by ../default.nix (derivations ai-sandbox-<name>).
{
  pkgs,
  lib,
  home-manager,
}: let
  helpers = import ./lib.nix {inherit pkgs lib home-manager;};
  profileRows = import ./profile-rows.nix {inherit lib helpers;};
  inherit (helpers) aiFixtureWith aiAllProfileNames mkAssertionCheck aiNoSandbox aiNoNvf aiNoGpu aiNoIsolation aiNoDisplay aiMediation aiMediationNvf aiEmittedProfiles aiUnixSocketGrants aiWithoutMediation aiMediationSockets aiGeneratedAliases aiExpectedNonoAliases aiAliasString aiWrapperArgv aiGpuVariants aiBasePack;
  # The ai-sandbox bases carry the pack's own grants, verbatim (./bases.nix): the mediation
  # switch changes the harness, service and variant profiles only.
  baseNames = lib.attrNames aiBasePack;
in {
  fixtures = mkAssertionCheck "ai-sandbox-fixtures" [
    {
      # The standalone fixtures (bare nixpkgs, no overlay, no flake inputs) must be able to evaluate
      # the module's own option defaults and force home.packages: a default that needed
      # anything the consumer does not provide would throw here.
      condition =
        builtins.length aiNoNvf.config.home.packages
        > 0;
      message = "standalone ai fixtures must evaluate home.packages";
    }
    {
      # The standalone fixture (the editor grants off, the default): the alias shape must not change, but
      # the editor grants inside the profile must vanish.
      # TMPDIR is not editor-gated: it neutralises the packs' $TMPDIR grant and
      # is required whether or not nvim is in play.
      #
      # Pinned as a literal, independently of aiExpectedAlias: this is the one
      # place the whole emitted string is reviewed rather than recomputed. Note
      # it no longer mentions the fixture's home dir -- the fallback root is the
      # logind runtime dir, so the alias is home-independent.
      #
      # Since the namespace isolation the alias runs nono through
      # ai-sandbox-run; the pre-isolation literal lives on in the next
      # assertion as `claude_nono`.
      condition =
        aiNoNvf.config.home.shellAliases.claude
        == "TMPDIR=\"\${TMPDIR:-/run/user/$UID}/claude/tmp\" sh -c 'mkdir -p -m 700 \"$TMPDIR\" && exec ai-sandbox-run --nono-alias claude_nono --open-urls-profile claude-local -- nono run --profile claude-local --allow-cwd -- claude \"$@\"' claude";
      message = "no-nvf fixture: the alias must keep TMPDIR but drop editor grants";
    }
    {
      # The pre-isolation literal of the assertion above, unchanged: the
      # nono-only twin must be byte for byte the alias as it was.
      condition =
        aiNoNvf.config.home.shellAliases.claude_nono or ""
        == "TMPDIR=\"\${TMPDIR:-/run/user/$UID}/claude/tmp\" sh -c 'mkdir -p -m 700 \"$TMPDIR\" && exec nono run --profile claude-local --allow-cwd -- claude \"$@\"' claude";
      message = "no-nvf fixture: claude_nono must be the pre-isolation alias literal";
    }
    {
      # `environment` no longer disappears wholesale: the cache-var pins are not
      # editor-gated, because they are what keeps persistent state out of a
      # RAM-backed TMPDIR. Only the runtime-dir redirect is editor-gated.
      condition = let
        p = builtins.fromJSON aiNoNvf.config.xdg.configFile."nono/profiles/claude-local.json".text;
        sv = p.environment.set_vars or {};
      in
        !(lib.elem "$XDG_STATE_HOME/nvf" (p.filesystem.allow or []))
        && !(sv ? XDG_RUNTIME_DIR)
        && sv.JITI_FS_CACHE or null == "$XDG_CACHE_HOME/claude/jiti";
      message = "no-nvf fixture: the runtime-dir redirect must disappear but the cache vars must stay";
    }
    {
      # The cache dirs are still created (they are not editor-gated), but with
      # no nvim there must be no runtime dir. The tmpdirs are deliberately
      # absent from activation now -- the alias creates them, because the
      # ambient branch is only known at run time.
      condition = let
        script = aiNoNvf.config.home.activation.aiSandboxDirs.data or "";
      in
        lib.hasInfix "\"/tmp/ai-test/.cache/claude\"" script
        && !(lib.hasInfix "/.cache/claude/tmp" script)
        && !(lib.hasInfix "/nvf/run-" script);
      message = "no-nvf fixture: cache dirs must be created but no tmpdir and no nvim runtime dir";
    }
    {
      # the sandbox toggle must remove the aliases, not just the nono package
      condition = !(aiNoSandbox.config.home.shellAliases ? claude);
      message = "no-sandbox fixture: disabling sandbox must drop the generated aliases";
    }
    {
      # The twins must be a removable layer: gpu.enable = false has to leave the
      # base aliases and profiles untouched, so a regression backs out cleanly.
      condition =
        !(aiNoGpu.config.home.shellAliases ? claude_gpu)
        && !(aiNoGpu.config.xdg.configFile ? "nono/profiles/claude-local-gpu.json")
        && aiNoGpu.config.home.shellAliases.claude == aiNoNvf.config.home.shellAliases.claude
        && aiNoGpu.config.xdg.configFile."nono/profiles/claude-local.json".text
        == aiNoNvf.config.xdg.configFile."nono/profiles/claude-local.json".text;
      message = "no-gpu fixture: disabling the twins must leave the base aliases and profiles unchanged";
    }
    {
      # sandbox.enable = false must drop the twins too, not just the base
      # aliases -- otherwise the escape hatch leaves the widest aliases behind.
      condition = !(aiNoSandbox.config.home.shellAliases ? claude_gpu);
      message = "no-sandbox fixture: disabling the sandbox must drop the GPU twins too";
    }
  ];

  isolation = mkAssertionCheck "ai-sandbox-isolation" [
    {
      # isolation.enable = false is the per-user way back. Every
      # generated alias is its nono-only string again, no `_nono` twin exists
      # (it would equal the alias), and the wrapper is not installed.
      condition = let
        c = aiNoIsolation.config;
        a = c.home.shellAliases;
      in
        !c.programs.aiSandbox.isolation.enable
        && aiGeneratedAliases c != []
        && lib.all (n: a.${n} == (aiExpectedNonoAliases c).${n}) (aiGeneratedAliases c)
        && lib.all (n: !(a ? "${n}_nono")) (aiGeneratedAliases c)
        && !(lib.any (p: (p.pname or p.name or "") == "ai-sandbox-run") c.home.packages);
      message = "ai-isolation-off: isolation.enable = false must restore the nono-only aliases, without twins or wrapper";
    }
    {
      # Mediation on: with the switch on, every profile carries mediation
      # and exactly the socket grant set -- a harness with an extra socket grant
      # also below it, display twins connect in /tmp/.X11-unix -- and
      # nothing else changes: minus the delta, each profile is the one the
      # switch-off fixture emits.
      condition = let
        all = aiEmittedProfiles aiMediation.config;
        allOff = aiEmittedProfiles aiNoNvf.config;
        ps = removeAttrs all baseNames;
        off = removeAttrs allOff baseNames;
        want = n:
          {
            unix_socket = aiMediationSockets;
            unix_socket_subtree_bind = ["$TMPDIR"] ++ lib.optional (n == "svc-test") "$HOME/.svc";
          }
          // lib.optionalAttrs (lib.hasSuffix "-gpu" n) {unix_socket_dir = ["/tmp/.X11-unix"];};
      in
        lib.attrNames all
        == lib.sort lib.lessThan (lib.attrNames allOff ++ ["svc-test"])
        && lib.all (b: all ? ${b} && all.${b} == allOff.${b}) baseNames
        && lib.all (n:
          ps.${n}.linux
          == {af_unix_mediation = "pathname";}
          && aiUnixSocketGrants ps.${n} == want n)
        (lib.attrNames ps)
        && lib.all (n: aiWithoutMediation ps.${n} == off.${n}) (lib.attrNames off);
      message = "ai-mediation-on: the mediation delta must be exactly the socket grant set";
    }
    {
      # Mediation, editor branch: with the nvf grants on, nvim's listen socket
      # lives in the profile's own runtime dir, which must be bindable -- and
      # it must be the very dir XDG_RUNTIME_DIR is redirected to.
      condition = let
        ps = removeAttrs (aiEmittedProfiles aiMediationNvf.config) baseNames;
      in
        ps
        != {}
        && lib.all (n: let
          p = ps.${n};
        in
          p.filesystem.unix_socket_subtree_bind
          == ["$TMPDIR" "$XDG_STATE_HOME/nvf/run-${n}"] ++ lib.optional (n == "svc-test") "$HOME/.svc"
          && lib.elem p.environment.set_vars.XDG_RUNTIME_DIR p.filesystem.unix_socket_subtree_bind)
        (lib.attrNames ps);
      message = "ai-mediation-on-editor: with the editor grants, each profile must also bind below its own nvf runtime dir";
    }
    {
      # gpu.display = false: the twin has no X11 grant, so the wrapper must
      # not bind /tmp/.X11-unix into its private /tmp either. Still wrapped,
      # still with its fail-closed hint.
      condition = let
        c = aiNoDisplay.config;
      in
        lib.all (v:
          c.home.shellAliases.${v}
          == aiAliasString (aiWrapperArgv {
            alias = v;
            profile = "${c.programs.aiSandbox.harnessProfiles.${aiGpuVariants.${v}}}-gpu";
          }) ["--allow-gpu"]
          c
          aiGpuVariants.${v}
          "${c.programs.aiSandbox.harnessProfiles.${aiGpuVariants.${v}}}-gpu")
        (lib.attrNames aiGpuVariants);
      message = "ai-gpu-no-display: with gpu.display = false the GPU aliases must not pass --x11";
    }
  ];

  aliases = import ./aliases.nix {inherit lib helpers;};

  home = import ./home.nix {inherit lib pkgs helpers;};

  inherit (import ./packs.nix {inherit pkgs lib helpers;}) packs-pins packs-activation;

  services = import ./services.nix {inherit lib pkgs helpers;};

  variants = import ./variants.nix {inherit lib helpers;};

  nixos = import ./nixos.nix {inherit lib helpers;};

  harnesses = import ./harnesses.nix {inherit lib pkgs helpers;};

  profile-unit = import ./profile-unit.nix {inherit lib helpers;};

  bases = import ./bases.nix {inherit lib helpers;};

  # The sandbox module alone: the profile files, the exact emitted set, the
  # reclaim of the files nono rewrites, and the off switch.
  profiles = let
    h = aiNoNvf.config;
    names = lib.sort lib.lessThan (aiAllProfileNames ++ baseNames);
    off = (aiFixtureWith {programs.aiSandbox.enable = false;}).config;
  in
    mkAssertionCheck "ai-sandbox-profiles" ([
        {
          condition = lib.attrNames (aiEmittedProfiles h) == names;
          message = "ai-sandbox alone must emit exactly the four harness profiles, the two GPU twins and the claude base (got: ${lib.concatStringsSep ", " (lib.attrNames (aiEmittedProfiles h))})";
        }
        {
          # nono rewrites a profile in place, which breaks HM's clobber check: every emitted
          # file has to be on the reclaim list, or the next switch aborts.
          condition = lib.all (n: lib.hasInfix "/nono/profiles/${n}.json" h.home.activation.nonoProfileReclaim.data) names;
          message = "the profile reclaim must name every emitted profile file";
        }
        {
          condition = aiEmittedProfiles off == {} && !(off.home.activation ? nonoProfileReclaim);
          message = "programs.aiSandbox.enable = false must emit no profile and no reclaim step";
        }
      ]
      ++ profileRows {
        home = h;
        aliases = false;
      });
}
