# The runner of the checks that ask the real nono about the rendered profiles (claude-why,
# opencode-why): the profiles of the render (the module's output, = profiles/ by
# `render-profiles`) in a fresh home, `nono why` for every case of every profile, then one
# run per profile that prints the session's environment. No pack store but the paths a check
# makes, no network: the bases extend nono's built-in `default`.
{
  pkgs,
  lib,
  render,
}: {
  # the check's name, the prefix of every message
  name,
  # the profiles every case is asked of
  profiles,
  # [path below the home, op, the verdict nono must give]
  cases,
  # dirs below the home, made before nono runs. Every case path exists too: one that `dirs`
  # does not make is an empty file (and its parent dirs). nono drops a grant on a path that
  # does not exist, so a `denied` on a missing file would prove nothing (a leaf `allow_file`
  # on it would pass), and an `allowed` would fail for the wrong reason.
  dirs ? [],
  # the profiles of the runs, and the variables each session must have: name -> path below the home
  envProfiles,
  envHome,
}: let
  q = lib.escapeShellArg;
  casePaths = lib.unique (map (c: lib.elemAt c 0) cases);
in
  pkgs.runCommand name {nativeBuildInputs = [pkgs.nono pkgs.jq pkgs.coreutils pkgs.gnugrep];} ''
    # beside the home, not around it: nono refuses a grant ($TMPDIR) that holds its own state
    export HOME=$PWD/home XDG_CONFIG_HOME=$PWD/home/.config XDG_CACHE_HOME=$PWD/home/.cache TMPDIR=$PWD/tmp
    mkdir -p "$XDG_CONFIG_HOME/nono/profiles" "$TMPDIR"
    ${lib.concatMapStrings (d: "mkdir -p \"$HOME\"/${q d}\n") dirs}
    ${lib.concatMapStrings (p: ''
        mkdir -p "$(dirname "$HOME"/${q p})"
        [ -e "$HOME"/${q p} ] || : >"$HOME"/${q p}
      '')
      casePaths}
    cp ${render.tree}/profiles/*.json "$XDG_CONFIG_HOME/nono/profiles/"
    fail=0
    ${lib.concatMapStrings (p:
      lib.concatMapStrings (c: let
        path = lib.elemAt c 0;
        op = lib.elemAt c 1;
        want = lib.elemAt c 2;
      in ''
        got=$(nono why --json --profile ${p} --path "$HOME"/${q path} --op ${op} 2>why.err | jq -r .status) || got="error: $(cat why.err)"
        if [ "$got" != ${want} ]; then
          echo ${q "${name}: nono why --profile ${p} --path ~/${path} --op ${op}: "}"$got, want ${want}" >&2
          fail=1
        fi
      '')
      cases)
    profiles}
    # The sessions the profiles run: the variables come from the base (the leaf does not set them).
    ${lib.concatMapStrings (p: ''
        env=$(nono run --profile ${p} -- ${pkgs.coreutils}/bin/env 2>run.err) || {
          echo ${q "${name}: nono run --profile ${p} failed: "}"$(cat run.err)" >&2
          exit 1
        }
        ${lib.concatStrings (lib.mapAttrsToList (var: rel: ''
            printf '%s\n' "$env" | grep -qxF ${var}="$HOME"/${q rel} || {
              echo ${q "${name}: a session of ${p} lacks ${var}=~/${rel}: "}"$(printf '%s\n' "$env" | grep '^${var}=' || true)" >&2
              fail=1
            }
          '')
          envHome)}
      '')
      envProfiles}
    [ "$fail" = 0 ] || exit 1
    touch $out
  ''
