# The per-harness pre-start hook (`harnesses.<name>.preStart`), over the standalone fixtures of
# ./lib.nix. Wired by ./default.nix as `prestart` (the alias strings) and `prestart-run` (the
# aliases run in bash, zsh and dash-as-sh against stub `ai-sandbox-run`, `nono` and harness).
{
  lib,
  pkgs,
  helpers,
}: let
  inherit (helpers) mkAssertionCheck aiFixtureWith aiNoNvf;
  base = aiNoNvf.config;
  with_ = extra: (aiFixtureWith extra).config;

  # Single quotes, `$`, a double quote, a backslash and newlines: none of it may reach an alias.
  hook = ''
    export PRESTART_VAR='it'"'"'s $HOME "q" \n'
    printf 'hook-stdout\n'
    if [ -d "$TMPDIR" ]; then echo hook-tmpdir-exists >&2; fi
    read -r stolen || :
    false
  '';
  # A plain variant of pi (twinned) and one with gitDirs (no twin).
  variants = {
    pi_web = {
      harness = "pi";
      suffix = "web";
    };
    pi_cfg = {
      harness = "pi";
      suffix = "cfg";
      gitDirs = ["$HOME/src/config.git"];
    };
  };
  hooked = with_ {
    programs.aiSandbox.harnesses.pi.preStart = hook;
    programs.aiSandbox.variants = variants;
  };
  # The same without the hook: the reference for "only the hook segment differs".
  unhooked = with_ {programs.aiSandbox.variants = variants;};
  a = hooked.home.shellAliases;
  file = hooked.programs.aiSandbox.internal.preStartFiles.pi;
  segment = "{ . ${file} || :; } </dev/null >&2 && ";
  piAliases = ["pi" "pi_nono" "pi_web" "pi_web_nono" "pi_cfg"];
  otherAliases = lib.subtractLists piAliases (lib.attrNames a);
  insert = s: builtins.replaceStrings ["\"$TMPDIR\" && exec "] ["\"$TMPDIR\" && ${segment}exec "] s;
  noIso = with_ {
    programs.aiSandbox.harnesses.pi.preStart = hook;
    programs.aiSandbox.isolation.enable = false;
  };
  render = c:
    c.programs.aiSandbox.render.command {
      command = "pi";
      profile = "pi-claude";
      alias = "pi";
    };
in {
  prestart = mkAssertionCheck "ai-sandbox-prestart" ([
      {
        condition = lib.all (h: h.preStart == "") (lib.attrValues base.programs.aiSandbox.harnesses) && base.programs.aiSandbox.internal.preStartFiles == {};
        message = "prestart: no harness has a hook by default, and no hook file is built";
      }
      {
        # Absent, empty or blank: the aliases stay byte for byte what they are without the option.
        condition = lib.all (v: (with_ {programs.aiSandbox.harnesses.pi.preStart = v;}).home.shellAliases == base.home.shellAliases) ["" "\n" "  \n\t\n"];
        message = "prestart: an empty or blank preStart must leave every alias byte-identical";
      }
      {
        # Pinned as literals: the hook segment sits between the mkdir and the exec, in the
        # wrapped alias and in its nono-only twin.
        condition =
          a.pi
          == "TMPDIR=\"\${TMPDIR:-/run/user/$UID}/pi/tmp\" sh -c 'mkdir -p -m 700 \"$TMPDIR\" && { . ${file} || :; } </dev/null >&2 && exec ai-sandbox-run --nono-alias pi_nono --open-urls-profile pi-claude -- nono run --profile pi-claude --allow-cwd -- pi \"$@\"' pi"
          && a.pi_nono
          == "TMPDIR=\"\${TMPDIR:-/run/user/$UID}/pi/tmp\" sh -c 'mkdir -p -m 700 \"$TMPDIR\" && { . ${file} || :; } </dev/null >&2 && exec nono run --profile pi-claude --allow-cwd -- pi \"$@\"' pi";
        message = "prestart: pi and pi_nono must be the pinned literals with the hook segment";
      }
      {
        # Every alias derived from the harness (base, twin, variants and their twins) carries the
        # hook and differs from its hook-free self by the segment only; no other alias changes.
        condition =
          lib.all (n: a.${n} == insert unhooked.home.shellAliases.${n}) piAliases
          && lib.all (n: a.${n} == unhooked.home.shellAliases.${n}) otherAliases;
        message = "prestart: every alias of the harness (variants and _nono twins included) and no other must gain exactly the hook segment";
      }
      {
        # Quoting: the hook text reaches the alias only as a store path of shell-safe characters;
        # the file holds it verbatim.
        condition =
          builtins.match "[A-Za-z0-9/._+=-]+" "${file}"
          != null
          && file.text or null == hook
          && lib.all (n: !(lib.hasInfix "PRESTART_VAR" a.${n}) && !(lib.hasInfix "hook-stdout" a.${n})) piAliases;
        message = "prestart: the hook must reach the aliases as a shell-safe store path only, the file holding it verbatim";
      }
      {
        condition = noIso.home.shellAliases.pi == insert (with_ {programs.aiSandbox.isolation.enable = false;}).home.shellAliases.pi && !(noIso.home.shellAliases ? pi_nono);
        message = "prestart: with the isolation off the (nono-only) alias carries the hook, and there is no twin";
      }
      {
        # render.command builds a consumer's own line (another harness's profile, say): never a hook.
        condition = render hooked == render base;
        message = "prestart: render.command must not include a harness's hook";
      }
      {
        condition =
          (with_ {
            programs.aiSandbox.harnesses.pi.preStart = hook;
            programs.aiSandbox.extraAliases.pi = "echo mine";
          }).home.shellAliases.pi
          == "echo mine";
        message = "prestart: an extraAliases entry stays the user's text, without the hook";
      }
      {
        condition =
          (with_ {
            programs.aiSandbox.harnesses.pi.preStart = hook;
            programs.aiSandbox.harnesses.pi.enable = false;
          }).programs.aiSandbox.internal.preStartFiles
          == {};
        message = "prestart: a disabled harness builds no hook file";
      }
    ]
    # The downstream alias rows hold over a home with a hook.
    ++ import ./profile-rows.nix {inherit lib helpers;} {
      home = hooked;
      files = false;
    });

  # The aliases run: the hook is sourced after the mkdir with stdin from /dev/null and stdout to
  # stderr, a failing last command does not stop the harness, its exports reach the harness, the
  # piped prompt and the arguments arrive intact; an `exit` aborts; a syntax error fails the build.
  prestart-run = let
    stubs = pkgs.runCommand "prestart-stubs" {} ''
      mkdir -p $out/bin
      for w in ai-sandbox-run nono; do
        cat >$out/bin/$w <<'EOF'
      #!${pkgs.dash}/bin/dash
      while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
      shift
      exec "$@"
      EOF
      done
      cat >$out/bin/pi <<'EOF'
      #!${pkgs.dash}/bin/dash
      printf 'var=%s\n' "$PRESTART_VAR"
      printf 'cwd=%s\n' "$(pwd)"
      for x in "$@"; do printf 'arg=%s\n' "$x"; done
      printf 'stdin=%s\n' "$(cat)"
      EOF
      chmod +x $out/bin/*
    '';
    aborting = (with_ {programs.aiSandbox.harnesses.pi.preStart = "exit 3";}).home.shellAliases.pi;
    # The alias's own shell: a `cd` moves the harness; `set -e` is shell-dependent (dash aborts,
    # bash as sh ignores it inside `|| :`); a background process with its fds detached does not
    # hold the alias's pipe open.
    cdAlias = (with_ {programs.aiSandbox.harnesses.pi.preStart = "mkdir -p \"$TMPDIR/moved\" && cd \"$TMPDIR/moved\"";}).home.shellAliases.pi;
    setEAlias = (with_ {programs.aiSandbox.harnesses.pi.preStart = "set -e\nfalse";}).home.shellAliases.pi;
    daemonAlias = (with_ {programs.aiSandbox.harnesses.pi.preStart = "sleep 3 >/dev/null 2>&1 </dev/null &";}).home.shellAliases.pi;
    broken = (with_ {programs.aiSandbox.harnesses.pi.preStart = "if then fi (";}).programs.aiSandbox.internal.preStartFiles.pi;
    script = alias: ''
      alias pi=${lib.escapeShellArg alias}
      printf 'prompt\n' | pi a "b c" '$d'
    '';
    expected = pkgs.writeText "prestart-expected" ''
      var=it's $HOME "q" \n
      arg=a
      arg=b c
      arg=$d
      stdin=prompt
    '';
  in
    pkgs.runCommand "prestart-run" {
      nativeBuildInputs = [pkgs.bash pkgs.zsh pkgs.dash pkgs.diffutils pkgs.gnugrep];
      failed = pkgs.testers.testBuildFailure broken;
    } ''
      mkdir -p sh-dash && ln -s ${pkgs.dash}/bin/dash sh-dash/sh
      export TMPDIR=$PWD/t
      mkdir -p "$TMPDIR"
      printf 'shopt -s expand_aliases\n%s' ${lib.escapeShellArg (script a.pi)} >run.bash
      printf '%s' ${lib.escapeShellArg (script a.pi_nono)} >run.zsh
      for v in bash:bash:$PATH zsh:zsh:$PATH bash:dash:$PWD/sh-dash:$PATH; do
        shell=''${v%%:*}; rest=''${v#*:}; tag=''${rest%%:*}; path=''${rest#*:}
        f=run.bash opt=; [ "$shell" = zsh ] && f=run.zsh opt=-f
        PATH=${stubs}/bin:$path $shell $opt $f >out 2>err || { echo "prestart-run: $shell/$tag exited $?" >&2; cat err >&2; exit 1; }
        grep -v '^cwd=' out | diff -u ${expected} - || { echo "prestart-run: $shell/$tag harness saw the wrong environment, arguments or stdin" >&2; exit 1; }
        grep -qx hook-stdout err || { echo "prestart-run: $shell/$tag hook stdout must go to stderr" >&2; exit 1; }
        grep -qx hook-tmpdir-exists err || { echo "prestart-run: $shell/$tag hook ran before the TMPDIR mkdir" >&2; exit 1; }
        [ -d "$TMPDIR/pi/tmp" ] || { echo "prestart-run: $shell/$tag no per-CLI TMPDIR" >&2; exit 1; }
      done
      printf 'shopt -s expand_aliases\n%s' ${lib.escapeShellArg (script aborting)} >abort.bash
      rc=0; PATH=${stubs}/bin:$PATH bash abort.bash >out 2>&1 || rc=$?
      [ "$rc" = 3 ] && ! grep -q '^var=' out || { echo "prestart-run: a hook's exit must abort before the harness (rc $rc)" >&2; exit 1; }
      printf 'shopt -s expand_aliases\n%s' ${lib.escapeShellArg (script cdAlias)} >cd.bash
      PATH=${stubs}/bin:$PATH bash cd.bash >cdout 2>cderr || { echo "prestart-run: cd hook run failed" >&2; cat cderr >&2; exit 1; }
      grep -qx "cwd=$TMPDIR/pi/tmp/moved" cdout || { echo "prestart-run: a hook's cd must move the harness's working directory" >&2; exit 1; }
      mkdir -p sh-bash && ln -s ${pkgs.bash}/bin/bash sh-bash/sh
      printf 'shopt -s expand_aliases\n%s' ${lib.escapeShellArg (script setEAlias)} >sete.bash
      rc=0; PATH=${stubs}/bin:$PWD/sh-bash:$PATH bash sete.bash >out 2>err || rc=$?
      [ "$rc" = 0 ] && grep -q '^var=' out || { echo "prestart-run: bash as sh must ignore set -e in the hook's || context (rc $rc)" >&2; exit 1; }
      rc=0; PATH=${stubs}/bin:$PWD/sh-dash:$PATH bash sete.bash >out 2>err || rc=$?
      [ "$rc" != 0 ] && ! grep -q '^var=' out || { echo "prestart-run: dash as sh must abort on set -e in the hook" >&2; exit 1; }
      printf 'shopt -s expand_aliases\n%s' ${lib.escapeShellArg (script daemonAlias)} >daemon.bash
      start=$(date +%s)
      PATH=${stubs}/bin:$PATH bash daemon.bash 2>&1 | cat >dout
      [ $(( $(date +%s) - start )) -lt 3 ] || { echo "prestart-run: a detached background process must not hold the alias's pipe" >&2; exit 1; }
      grep -q 'Syntax error\|syntax error' $failed/testBuildFailure.log || { echo "prestart-run: a hook with a syntax error must fail its build" >&2; exit 1; }
      touch $out
    '';
}
