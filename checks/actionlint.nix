# `actionlint` over every workflow file (it runs `shellcheck` on `run:` steps
# when that is on PATH).
{
  pkgs,
  self,
}:
pkgs.runCommand "actionlint" {nativeBuildInputs = [pkgs.actionlint pkgs.shellcheck];} ''
  cd ${self}
  files=(.github/workflows/*.yml)
  [ -e "''${files[0]}" ] || { echo "actionlint: no workflow under .github/workflows" >&2; exit 1; }
  actionlint "''${files[@]}"
  touch $out
''
