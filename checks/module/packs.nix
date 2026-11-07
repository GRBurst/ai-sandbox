# The nono packs the enabled harnesses and services need (scripts/packs), at activation: the
# module names each pinned pack with the exact `nono pull <pack>@<version>` line, and an
# unpinned one with `nono pull <pack>`. Over the standalone fixtures of ./lib.nix.
{
  pkgs,
  lib,
  helpers,
}: let
  inherit (helpers) mkAssertionCheck aiFixtureWith;
  act = cfg: cfg.home.activation.aiSandboxPacks.data or "";
  # Literal, not read back from scripts/packs: a changed pin has to fail here.
  pins = {
    "nolabs-ai/antigravity" = "0.3.4";
    "nolabs-ai/claude" = "0.1.4";
    "nolabs-ai/opencode" = "0.1.3";
    "nolabs-ai/pi" = "0.2.2";
  };
  default = (aiFixtureWith {}).config;
  customPack =
    (aiFixtureWith {
      programs.aiSandbox.harnesses.svc = {
        profileName = "svc-test";
        pack = "p/t";
      };
    }).config;
  piOff = (aiFixtureWith {programs.aiSandbox.harnesses.pi.enable = false;}).config;

  # The activation under a stub nono: `list --installed --json` prints $NONO_STUB_LIST and exits
  # $NONO_STUB_EXIT, after writing $NONO_STUB_ERR to stderr; $NONO_STUB_HANG makes it hang. Every
  # call is logged, an open stdin is logged too, any other call exits 2.
  stub = pkgs.writeShellScriptBin "nono" ''
    echo "$*" >> "''${NONO_STUB_LOG:?}"
    read -r -t 0.5 _ 2>/dev/null && rc=0 || rc=$?
    if [ "$rc" -gt 1 ]; then echo "stdin was open" >> "$NONO_STUB_LOG"; fi
    if [ "$*" = "list --installed --json" ]; then
      [ -z "''${NONO_STUB_HANG:-}" ] || exec sleep 60
      [ -z "''${NONO_STUB_ERR:-}" ] || echo "$NONO_STUB_ERR" >&2
      cat "''${NONO_STUB_LIST:?}"
      exit "''${NONO_STUB_EXIT:-0}"
    fi
    exit 2
  '';
  # pipefail and -e like Home Manager's activation script
  mkActFile = pkg:
    pkgs.writeText "packs-activation.sh" ''
      warnEcho() { echo "WARN $*"; }
      set -eu -o pipefail
      ${act (aiFixtureWith {programs.aiSandbox.package = pkg;}).config}
    '';
  actFile = mkActFile stub;
  # A package without bin/nono
  actNoNono = mkActFile (pkgs.runCommand "no-nono" {} "mkdir -p $out/bin");
  listing = name: packs:
    pkgs.writeText "nono-list-${name}.json" (builtins.toJSON {
      lockfile_version = 4;
      registry = "https://registry.nono.sh";
      packages = lib.mapAttrs (_: v: {version = v;}) packs;
    });
  textList = name: text: pkgs.writeText "nono-list-${name}.json" text;
  empty = listing "empty" {};
  allPinned = listing "pinned" pins;
  piOld = listing "pi-old" (pins // {"nolabs-ai/pi" = "0.0.1";});
  noText = textList "none" "";
  notJson = textList "garbage" "nono: not json at all\n";
  packagesArray = textList "array" (builtins.toJSON {packages = ["nolabs-ai/pi"];});
  pullLines = lib.concatMapStrings (p: ''
    grep -qF ${lib.escapeShellArg "nono pull ${p}@${pins.${p}}"} "$1" || fail "$1: no pull line for ${p}"
  '') (lib.attrNames pins);
in {
  packs-pins = mkAssertionCheck "ai-sandbox-packs-pins" [
    {
      condition = lib.all (p: lib.hasInfix "nono pull ${p}@${pins.${p}}" (act default)) (lib.attrNames pins);
      message = "packs: the activation must name the exact nono pull line of every pinned pack the harnesses need";
    }
    {
      condition = lib.hasInfix "nono pull p/t" (act customPack);
      message = "packs: an unpinned pack of a harness must be named with a bare nono pull line";
    }
    {
      condition = !(lib.hasInfix "nolabs-ai/pi" (act piOff));
      message = "packs: a disabled harness must not name its pack";
    }
  ];

  # States: a fresh home, one pack at another version, all at the pins, and nono's list
  # unreadable (nono failing, missing, no output, not JSON, another shape, hanging): one warning
  # naming every pull line there. Never a pull, always exit 0.
  packs-activation = pkgs.runCommand "ai-sandbox-packs-activation" {} ''
    work=$PWD/work
    mkdir -p $work
    fail() { echo "packs-activation: $*" >&2; exit 1; }
    pulls() {
      ${pullLines}
    }
    # run <state> <listing> <exit> [script]: one activation; it must exit 0 and call nono with list only
    run() {
      NONO_STUB_LIST=$2 NONO_STUB_EXIT=$3 NONO_STUB_LOG=$work/log-$1 bash ''${4:-${actFile}} > $work/out-$1 2>&1 \
        || fail "$1: the activation failed: $(cat $work/out-$1)"
      if grep -vxF 'list --installed --json' $work/log-$1 > /dev/null 2>&1; then
        fail "$1: nono was called with more than list: $(cat $work/log-$1)"
      fi
    }
    # unreadable <state> <reason>: exactly one warning, with the reason and every pull line
    unreadable() {
      [ "$(wc -l < $work/out-$1)" = 1 ] || fail "$1: want exactly one line: $(cat $work/out-$1)"
      grep -qF "cannot read nono's pack list" $work/out-$1 || fail "$1: want the cannot-read warning: $(cat $work/out-$1)"
      grep -qF "$2" $work/out-$1 || fail "$1: want the reason '$2': $(cat $work/out-$1)"
      pulls $work/out-$1
    }
    # Fresh home, nothing installed: one line per required pack, each naming its pull
    run s1 ${empty} 0
    [ "$(grep -c '^WARN' $work/out-s1)" = 4 ] || fail "s1: want one warning per pack"
    grep -qF 'nono lacks the pack' $work/out-s1 || fail "s1: want the lacks warning"
    pulls $work/out-s1
    # One pack at another version: one warning, no action
    run s2 ${piOld} 0
    [ "$(wc -l < $work/out-s2)" = 1 ] || fail "s2: want exactly one line"
    grep -qF 'is at 0.0.1, not at 0.2.2' $work/out-s2 || fail "s2: want the version-mismatch warning"
    # Everything at its pin: silent
    run s3 ${allPinned} 0
    [ ! -s $work/out-s3 ] || fail "s3: want no output"
    # nono fails: one warning with the first stderr line only
    NONO_STUB_ERR=$'nono: boom\nsecond line' run s4 ${empty} 1
    unreadable s4 'nono: boom'
    ! grep -qF 'second line' $work/out-s4 || fail "s4: want only the first stderr line"
    # nono is not there
    run s5 ${empty} 0 ${actNoNono}
    unreadable s5 'cannot read'
    # nono prints nothing, or no JSON, or another shape
    run s6 ${noText} 0
    unreadable s6 'cannot read'
    run s7 ${notJson} 0
    unreadable s7 'cannot read'
    run s8 ${packagesArray} 0
    unreadable s8 'cannot read'
    # nono hangs: cut off after a short while
    NONO_STUB_HANG=1 run s9 ${empty} 0
    unreadable s9 'timed out'
    # nono must not be handed the activation's stdin
    sleep 3 | run s10 ${allPinned} 0
    [ ! -s $work/out-s10 ] || fail "s10: want no output"
    touch $out
  '';
}
