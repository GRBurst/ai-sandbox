# Public leak check.
#
# Scans the whole flake source for generic personal-data patterns, and
# self-tests the scanner against the fixtures: every `bad/` fixture must hit
# (and the hit must contain its `# expect:` substring), every `good/` fixture
# must not. The first line of a bad fixture is metadata and is stripped
# before the scan.
{
  pkgs,
  self,
}: let
  leakScan = pkgs.writeShellApplication {
    name = "leak-scan";
    runtimeInputs = [pkgs.ripgrep pkgs.gnugrep pkgs.coreutils];
    text = builtins.readFile ./scan.sh;
  };
in
  pkgs.runCommand "leaks" {nativeBuildInputs = [leakScan pkgs.gnused pkgs.gnugrep];} ''
    fail=0

    for f in ${./fixtures/bad}/*; do
      case=bad/''${f##*/}
      expect=$(sed -n '1s/^# expect: //p' "$f")
      if [ -z "$expect" ]; then
        echo "leaks: $case has no '# expect:' first line"; fail=1; continue
      fi
      rm -rf probe; mkdir probe; tail -n +2 "$f" > "probe/''${f##*/}"
      if leak-scan probe >out 2>&1; then
        echo "leaks: $case was not refused"; fail=1
      elif ! grep -qF -- "$expect" out; then
        echo "leaks: $case refused without '$expect':"; cat out; fail=1
      fi
    done

    for f in ${./fixtures/good}/*; do
      case=good/''${f##*/}
      rm -rf probe; mkdir probe; cp "$f" probe/
      if ! leak-scan probe >out 2>&1; then
        echo "leaks: $case was refused:"; cat out; fail=1
      fi
    done


    # whole-tree fixtures (expected.txt, flake.nix/flake.lock exemptions):
    # a bad tree's EXPECT file holds the substring its refusal must contain
    for d in ${./fixtures/trees/bad}/*; do
      case=trees/bad/''${d##*/}
      expect=$(cat "$d/EXPECT")
      rm -rf probe; mkdir probe; cp -r "$d"/. probe/; chmod -R u+w probe; rm probe/EXPECT
      if leak-scan probe >out 2>&1; then
        echo "leaks: $case was not refused"; fail=1
      elif ! grep -qF -- "$expect" out; then
        echo "leaks: $case refused without '$expect':"; cat out; fail=1
      fi
    done

    for d in ${./fixtures/trees/good}/*; do
      case=trees/good/''${d##*/}
      rm -rf probe; mkdir probe; cp -r "$d"/. probe/; chmod -R u+w probe
      if ! leak-scan probe >out 2>&1; then
        echo "leaks: $case was refused:"; cat out; fail=1
      fi
    done

    if ! leak-scan ${self} >out 2>&1; then
      echo "leaks: the flake source contains personal data:"; cat out; fail=1
    fi

    [ "$fail" = 0 ] || exit 1
    touch $out
  ''
