# Aliases of the sandbox module (tmpdirs, the isolation wrapper, the nono-only twins and the
# two module assertions), over the standalone fixtures of ./lib.nix. Wired by ./default.nix as
# ai-sandbox-aliases.
{
  lib,
  helpers,
}: let
  inherit (helpers) mkAssertionCheck aiNoNvf aiFixtureWith aiFailedWith aiFailsWith;
  h = aiNoNvf.config;
  with_ = extra: (aiFixtureWith extra).config;
  override = with_ {
    programs.aiSandbox.extraAliases = {
      claude = "echo mine";
      extra = "echo extra";
    };
  };
  userAlias = with_ {home.shellAliases.claude = "echo user";};

  # Every spelling of a two-segment root: trailing, repeated and `.` segments, and a `..`.
  spellings = r: let
    seg = lib.tail (lib.splitString "/" r);
    a = lib.head seg;
    b = lib.last seg;
  in [r "${r}/" "${r}//" "/${r}" "/${a}//${b}" "${r}/." "/${a}/./${b}" "/${a}/x/../${b}"];
  sharedRoots = lib.concatMap spellings ["/var/tmp" "/run/lock" "/dev/shm"];
in
  mkAssertionCheck "ai-sandbox-aliases" ([
      {
        # Pinned as a literal, independently of the helpers: the one place the whole string is
        # reviewed rather than recomputed. Home-independent: the fallback root is logind's dir.
        condition =
          h.home.shellAliases.claude
          == "TMPDIR=\"\${TMPDIR:-/run/user/$UID}/claude/tmp\" sh -c 'mkdir -p -m 700 \"$TMPDIR\" && exec ai-sandbox-run --nono-alias claude_nono --open-urls-profile claude-local -- nono run --profile claude-local --allow-cwd -- claude \"$@\"' claude"
          && h.home.shellAliases.claude_nono
          == "TMPDIR=\"\${TMPDIR:-/run/user/$UID}/claude/tmp\" sh -c 'mkdir -p -m 700 \"$TMPDIR\" && exec nono run --profile claude-local --allow-cwd -- claude \"$@\"' claude";
        message = "ai-sandbox alone: claude and claude_nono must be the pinned literals";
      }
      {
        condition = lib.attrNames (lib.filterAttrs (n: _: lib.hasSuffix "_nono" n) h.home.shellAliases) == ["agy_nono" "claude_gpu_nono" "claude_nono" "opencode_gpu_nono" "opencode_nono" "pi_nono"];
        message = "ai-sandbox alone: one _nono twin per alias, GPU variants included";
      }
      {
        # `extraAliases` replaces a generated alias of the same name and adds new ones; the
        # twin of the replaced alias stays.
        condition =
          override.home.shellAliases.claude
          == "echo mine"
          && override.home.shellAliases.extra == "echo extra"
          && override.home.shellAliases.claude_nono == h.home.shellAliases.claude_nono;
        message = "extraAliases must override a generated alias, add new ones and leave the _nono twin";
      }
      {
        # Generated aliases are mkDefault, so a shell module (the terminal kit's zsh) can
        # still set its own without a conflict.
        condition = userAlias.home.shellAliases.claude == "echo user";
        message = "a plain home.shellAliases entry must win over the generated alias (mkDefault)";
      }
      {
        # `render.command`: what consumers (pi-claude-login) build their command line with.
        condition =
          h.programs.aiSandbox.render.command {
            command = "claude";
            profile = "pi-claude";
            tmpLeaf = "pi";
          }
          == "TMPDIR=\"\${TMPDIR:-/run/user/$UID}/pi/tmp\" sh -c 'mkdir -p -m 700 \"$TMPDIR\" && exec ai-sandbox-run --open-urls-profile pi-claude -- nono run --profile pi-claude --allow-cwd -- claude \"$@\"' claude"
          && (with_ {programs.aiSandbox.isolation.enable = false;}).programs.aiSandbox.render.command {
            command = "claude";
            profile = "pi-claude";
            tmpLeaf = "pi";
          }
          == "TMPDIR=\"\${TMPDIR:-/run/user/$UID}/pi/tmp\" sh -c 'mkdir -p -m 700 \"$TMPDIR\" && exec nono run --profile pi-claude --allow-cwd -- claude \"$@\"' claude";
        message = "render.command must print the alias string, wrapped with the isolation on and nono-only with it off";
      }
      {
        condition = aiFailedWith {} == [] && aiFailedWith {programs.aiSandbox.tmpdirFallback = "/var/lib/ai-tmp";} == [] && aiFailedWith {programs.aiSandbox.gpu.variants.claude_gpu = "agy";} == [];
        message = "the default fixture, a private fallback root and a variant of another harness must satisfy every module assertion";
      }
      {
        # Negative: a variant naming no harness at all (a profile name instead of a key). One
        # mistake, one message: the generated variant does not trip the generic variants check too.
        condition =
          aiFailsWith "ai-sandbox: programs.aiSandbox.gpu.variants names command(s) with no entry"
          {programs.aiSandbox.gpu.variants.bogus_gpu = "no-such-harness";};
        message = "a GPU variant naming no harness must fail exactly the gpu.variants module assertion";
      }
      {
        # Negative: a world-writable fallback root lets another process pre-create the leaf.
        condition = lib.all (v: aiFailsWith "ai-sandbox: programs.aiSandbox.tmpdirFallback must be an absolute path" {programs.aiSandbox.tmpdirFallback = v;}) ["/tmp" "/var/tmp" "/dev/shm" "/run/user" "/" "relative/dir"];
        message = "a relative or world-writable tmpdirFallback must fail the module assertion";
      }
      {
        # Negative: the guard compares the path, not its spelling. Trailing, repeated and `.`
        # segments still name the world-writable root (`/tmp//claude/tmp`), and `..` cannot be
        # resolved without the filesystem, so it is refused outright.
        condition = lib.all (v: aiFailsWith "ai-sandbox: programs.aiSandbox.tmpdirFallback must be an absolute path" {programs.aiSandbox.tmpdirFallback = v;}) ["/tmp/" "/tmp//" "//tmp" "/tmp/." "/run/user/" "/var//tmp" "//" "/var/lib/../../tmp"];
        message = "a world-writable tmpdirFallback spelled with trailing, repeated, `.` or `..` segments must fail the module assertion";
      }
      {
        # Negative: the other shared roots (/var/tmp, /run/lock, /dev/shm), in every spelling.
        condition = lib.all (v: aiFailsWith "ai-sandbox: programs.aiSandbox.tmpdirFallback must be an absolute path" {programs.aiSandbox.tmpdirFallback = v;}) sharedRoots;
        message = "tmpdirFallback /var/tmp, /run/lock or /dev/shm, however spelled, must fail the module assertion";
      }
      {
        # Control: a private directory under /var passes.
        condition = aiFailedWith {programs.aiSandbox.tmpdirFallback = "/var/lib/x";} == [];
        message = "tmpdirFallback /var/lib/x must satisfy every module assertion";
      }
      {
        # Control: a private root keeps passing with a trailing slash.
        condition = aiFailedWith {programs.aiSandbox.tmpdirFallback = "/var/lib/ai-tmp/";} == [];
        message = "a private tmpdirFallback with a trailing slash must satisfy every module assertion";
      }
    ]
    ++ import ./profile-rows.nix {inherit lib helpers;} {
      home = h;
      files = false;
    })
