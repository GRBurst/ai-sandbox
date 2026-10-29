# Citations never dangle. (1) Every `docs/<path>.md` named in a tracked text file
# exists in the source. (2) Every design id (`R8`, `S2.1`, `RF3`, `T1.4b`, `D10`,
# `F7`, `K6`, `A3`) cited in a tracked `.nix` or `.sh` file is defined in the
# isolation design extract as a bold item (`- **R8** ...`). The leak fixtures are
# test data and not scanned.
{
  pkgs,
  self,
}: let
  design = "docs/specs/2026-09-26-sandbox-namespace-isolation-design.md";
in
  pkgs.runCommand "doc-refs" {nativeBuildInputs = [pkgs.gnugrep pkgs.coreutils];} ''
    cd ${self}
    fail=0
    while IFS=: read -r f t; do
      case $f in ./checks/leaks/fixtures/*) continue ;; esac
      [ -e "$t" ] || { echo "doc-refs: $f cites $t, which does not exist"; fail=1; }
    done < <(grep -rIoE --exclude-dir=.git 'docs/[A-Za-z0-9._/-]+\.md' . | sort -u)
    # A shell variable such as `T2=` or `$T2` is not an id.
    while IFS=: read -r f id; do
      case $f in ./checks/leaks/fixtures/*) continue ;; esac
      grep -qF -e "**$id**" -e "**$id " ${design} ||
        { echo "doc-refs: $f cites $id, which ${design} does not define"; fail=1; }
    done < <(grep -rIoP --exclude-dir=.git --include='*.nix' --include='*.sh' \
      '(?<![$\w])(RF|R|S|T|D|F|K|A)\d+(\.\d+)?[a-z]?\b(?![=/])' . | sort -u)
    [ "$fail" = 0 ] || exit 1
    touch $out
  ''
