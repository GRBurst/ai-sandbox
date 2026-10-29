# `shell/variant.sh` (hand-written, sourced by bash and zsh) prints, byte for byte, the alias
# strings the module's alias builder produces. For the aliases of every render fixture (isolation
# on, off, and with a project-directory variant) and for `render.command`, a generated script
# calls `ai_sandbox_alias_string` with the arguments derived from the module's own data
# (`harnessProfiles`, `internal.variants`) and compares the output with the Nix value, once under
# bash and once under zsh. `ai_sandbox_variant` is compared through the alias table of each shell.
# The `TMPDIR` fallback is refused for exactly the values the module's assertion refuses.
{
  pkgs,
  lib,
  self,
  render,
  home-manager,
}: let
  helpers = import ./module/lib.nix {inherit pkgs lib home-manager;};
  q = lib.escapeShellArg;
  qs = lib.escapeShellArgs;

  # The arguments that make `ai_sandbox_alias_string` print the value of alias `k`.
  argsOf = {
    nonoOnly,
    c,
  }: let
    p = c.programs.aiSandbox;
    wrapped = alias: x11:
      if nonoOnly
      then ["--nono-only"]
      else lib.optional x11 "--x11" ++ ["--nono-alias" "${alias}_nono"];
    harness = lib.concatLists (lib.mapAttrsToList (h: prof: [
        {
          k = h;
          args = wrapped h false ++ [h prof];
        }
        {
          k = "${h}_nono";
          args = ["--nono-only" h prof];
        }
      ])
      p.harnessProfiles);
    variants = lib.concatLists (lib.mapAttrsToList (v: e: [
        {
          k = v;
          args = wrapped v e.spec.x11 ++ [e.command e.profile] ++ e.spec.nonoArgs;
        }
        {
          k = "${v}_nono";
          args = ["--nono-only" e.command e.profile] ++ e.spec.nonoArgs;
        }
      ])
      p.internal.variants);
    cases = lib.filter (x: c.home.shellAliases ? ${x.k}) (harness ++ variants);
    names = lib.sort lib.lessThan (map (x: x.k) cases);
    all = lib.sort lib.lessThan (lib.attrNames c.home.shellAliases);
  in
    if names == all
    then cases
    else throw "variant-sh: no arguments derived for the aliases ${toString (lib.subtractLists names all)}";

  fixtures = {
    fs = {
      c = render.fs;
      nonoOnly = false;
    };
    fs0 = {
      c = render.fs0;
      nonoOnly = true;
    };
    fsv = {
      c = render.fsv;
      nonoOnly = false;
    };
  };

  aliasCases = lib.concatStrings (lib.mapAttrsToList (
      fname: f:
        lib.concatMapStrings (x: ''
          check ${q "${fname}:${x.k}"} ${q f.c.home.shellAliases.${x.k}} "$(ai_sandbox_alias_string ${qs x.args})"
        '') (argsOf f)
    )
    fixtures);

  # `render.command` (a login helper running one harness in another's profile).
  commandCases = lib.concatStrings (lib.mapAttrsToList (fname: f: ''
      check ${q "${fname}:render.command"} ${q (f.c.programs.aiSandbox.render.command {
        command = "claude";
        profile = "pi-claude";
        tmpLeaf = "pi";
      })} "$(ai_sandbox_alias_string ${qs (lib.optional f.nonoOnly "--nono-only" ++ ["--tmp-leaf" "pi" "claude" "pi-claude"])})"
    '')
    fixtures);

  # The two environment variables: the default of NONO_ARGS is F_S's `nonoArgs`; other values replace it.
  claudeNono = render.fs.home.shellAliases.claude_nono;
  envCases = ''
    check 'env:NONO_ARGS empty' ${q (lib.replaceStrings [" --allow-cwd"] [""] claudeNono)} "$(AI_SANDBOX_NONO_ARGS= ai_sandbox_alias_string --nono-only claude claude-local)"
    check 'env:NONO_ARGS two' ${q (lib.replaceStrings ["--allow-cwd"] ["--allow-cwd --verbose"] claudeNono)} "$(AI_SANDBOX_NONO_ARGS='--allow-cwd --verbose' ai_sandbox_alias_string --nono-only claude claude-local)"
    check 'env:fallback' ${q (lib.replaceStrings ["/run/user/$UID"] ["/var/lib/ai-tmp"] claudeNono)} "$(AI_SANDBOX_TMPDIR_FALLBACK=/var/lib/ai-tmp ai_sandbox_alias_string --nono-only claude claude-local)"
  '';

  # Refused by the script exactly when the module's assertion fails; the module compares the
  # path, not its spelling (`/tmp/`, `//tmp`, `/tmp/.` are /tmp; a `..` segment is refused).
  probes = [
    "/tmp"
    "/var/tmp"
    "/dev/shm"
    "/run/user"
    "/"
    "relative/dir"
    ""
    "/run/user/$UID"
    "/run/user/1000"
    "/var/lib/ai-tmp"
    "/tmp/"
    "/tmp//"
    "//tmp"
    "/tmp/."
    "/run/user/"
    "/var//tmp"
    "//"
    "/var/lib/../../tmp"
    "/var/lib/ai-tmp/"
    "/var/lib/./ai-tmp"
    "/var/lib/x"
  ];
  refusedByModule = p:
    lib.any (m: lib.hasInfix "tmpdirFallback" m) (helpers.aiFailedWith {programs.aiSandbox.tmpdirFallback = p;});
  probeCases =
    lib.concatMapStrings (p: ''
      probe ${q p} ${
        if refusedByModule p
        then "1"
        else "0"
      }
    '')
    (probes ++ sharedRoots);

  # The shared roots /var/tmp, /run/lock and /dev/shm in every spelling (trailing, repeated and
  # `.` segments, and a `..`) are refused whatever the module says; the control passes.
  spellings = r: let
    seg = lib.tail (lib.splitString "/" r);
    a = lib.head seg;
    b = lib.last seg;
  in [r "${r}/" "${r}//" "/${r}" "/${a}//${b}" "${r}/." "/${a}/./${b}" "/${a}/x/../${b}"];
  sharedRoots = lib.concatMap spellings ["/var/tmp" "/run/lock" "/dev/shm"];
  fixedCases = lib.concatMapStrings (p: "probe ${q p} 1\n") sharedRoots + "probe /var/lib/x 0\n";

  # `ai_sandbox_variant` defines the alias and its `_nono` twin, the module's values.
  variantCases = let
    gpu = render.fs.home.shellAliases;
    notes = render.fsv.home.shellAliases;
  in ''
    ai_sandbox_variant --x11 claude_gpu claude claude-local-gpu --allow-gpu
    check 'variant:claude_gpu' ${q gpu.claude_gpu} "$(alias_value claude_gpu)"
    check 'variant:claude_gpu_nono' ${q gpu.claude_gpu_nono} "$(alias_value claude_gpu_nono)"
    ai_sandbox_variant pi_notes pi pi-claude-notes
    check 'variant:pi_notes' ${q notes.pi_notes} "$(alias_value pi_notes)"
    check 'variant:pi_notes_nono' ${q notes.pi_notes_nono} "$(alias_value pi_notes_nono)"
  '';

  probeFn = ''
    probe() { # probe FALLBACK WANT_EXIT: the exit code with that TMPDIR fallback
      ( AI_SANDBOX_TMPDIR_FALLBACK=$1; export AI_SANDBOX_TMPDIR_FALLBACK
        ai_sandbox_alias_string claude claude-local ) >/dev/null 2>&1
      rc=$?
      if [ "$rc" != "$2" ]; then
        printf 'FAIL probe %s: exit %s, want %s\n' "$1" "$rc" "$2"
        fail=1
      fi
    }
  '';

  # The fallback probes alone under a POSIX sh (dash): the guard uses no bash or zsh feature.
  probeScript = pkgs.writeText "variant-probes.sh" ''
    fail=0
    ${probeFn}
    unset AI_SANDBOX_NONO_ARGS AI_SANDBOX_TMPDIR_FALLBACK
    . ${self}/shell/variant.sh
    ${probeCases}
    ${fixedCases}
    [ "$fail" = 0 ]
  '';

  script = pkgs.writeText "variant-cases.sh" ''
    fail=0
    check() { # check NAME WANT GOT
      if [ "$3" != "$2" ]; then
        printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"
        fail=1
      fi
    }
    ${probeFn}
    usage_exit() { # usage_exit NAME ARG...: exit 2
      ( ai_sandbox_alias_string "$@" ) >/dev/null 2>&1
      rc=$?
      if [ "$rc" != 2 ]; then
        printf 'FAIL usage %s: exit %s, want 2\n' "$*" "$rc"
        fail=1
      fi
    }
    variant_exit() { # variant_exit ARG...: ai_sandbox_variant exits 2
      ( ai_sandbox_variant "$@" ) >/dev/null 2>&1
      rc=$?
      if [ "$rc" != 2 ]; then
        printf 'FAIL variant usage %s: exit %s, want 2\n' "$*" "$rc"
        fail=1
      fi
    }
    nono_args_exit() { # nono_args_exit VALUE: refused as AI_SANDBOX_NONO_ARGS (exit 2)
      ( AI_SANDBOX_NONO_ARGS=$1; export AI_SANDBOX_NONO_ARGS
        ai_sandbox_alias_string claude claude-local ) >/dev/null 2>&1
      rc=$?
      if [ "$rc" != 2 ]; then
        printf 'FAIL AI_SANDBOX_NONO_ARGS=%s: exit %s, want 2\n' "$1" "$rc"
        fail=1
      fi
    }
    alias_value() { # the definition of an alias in this shell's table
      if [ -n "''${BASH_VERSION-}" ]; then
        printf '%s' "''${BASH_ALIASES[$1]-}"
      else
        printf '%s' "''${aliases[$1]-}"
      fi
    }
    unset AI_SANDBOX_NONO_ARGS AI_SANDBOX_TMPDIR_FALLBACK
    . ${self}/shell/variant.sh
    ${aliasCases}
    ${commandCases}
    ${envCases}
    ${probeCases}
    ${fixedCases}
    usage_exit
    usage_exit claude
    usage_exit --bogus claude claude-local
    usage_exit --tmp-leaf
    # The arguments are pasted into the alias's `sh -c '…'` body: anything outside letters,
    # digits and _ . , : = + @ % / - is refused, never pasted; a name (COMMAND, leaf, alias)
    # has no / or = and is not . or ..
    usage_exit claude claude-local "a'b"
    usage_exit claude claude-local 'a b'
    usage_exit claude claude-local 'a;b'
    usage_exit claude claude-local '$HOME/x'
    usage_exit claude claude-local ""
    usage_exit "cl'aude" claude-local
    usage_exit claude 'claude local'
    usage_exit .. claude-local
    usage_exit a/b claude-local
    usage_exit --tmp-leaf "p'i" claude claude-local
    usage_exit --tmp-leaf .. claude claude-local
    usage_exit --tmp-leaf a/b claude claude-local
    usage_exit --nono-alias 'x;y' claude claude-local
    nono_args_exit "--allow-cwd'"
    nono_args_exit '--allow-cwd;x'
    nono_args_exit '--allow-cwd  --verbose'
    nono_args_exit ' --allow-cwd'
    probe "/var/lib/a'b" 2
    probe '/var/lib/a"b' 2
    probe '/var/lib/a b' 2
    probe '/var/lib/$(id)' 2
    probe '/var/lib/`id`' 2
    probe '/var/lib/a;b' 2
    probe '/var/lib/a\b' 2
    variant_exit "no'tes" pi pi-claude
    variant_exit . pi pi-claude
    variant_exit a=b pi pi-claude
    variant_exit notes pi pi-claude --allow "/home/u/My Notes"
    # The injection a quote allowed: the alias ran `: >variant-pwned` outside nono.
    rm -f variant-pwned
    ( ai_sandbox_variant notes pi pi-claude --allow "x'; : >variant-pwned; '"
      eval "$(alias_value notes_nono)" ) >/dev/null 2>&1
    if [ -e variant-pwned ]; then
      printf 'FAIL injection: a quote in NONO_ARG ran a command outside nono\n'
      rm -f variant-pwned
      fail=1
    fi
    ${variantCases}
    [ "$fail" = 0 ]
  '';
in
  pkgs.runCommand "variant-sh" {nativeBuildInputs = [pkgs.bash pkgs.zsh pkgs.dash];} ''
    for f in variant.sh aliases.sh; do
      bash -n ${self}/shell/$f
      zsh -n ${self}/shell/$f
    done
    echo "== bash"
    env -i ${pkgs.bash}/bin/bash ${script}
    echo "== zsh"
    env -i ${pkgs.zsh}/bin/zsh -f ${script}
    echo "== sh (dash), the fallback probes"
    env -i ${pkgs.dash}/bin/dash ${probeScript}
    touch $out
  ''
