# The modules and the wrapper stay generic: they name none of the coupling points of a
# particular host configuration, and a module never reads the rendered files. Three rules:
#   (1) no file under `modules/` or `packages/` holds a forbidden token on a non-comment line
#       (fixed strings, case-sensitive): a host-side argument or option namespace (`osConfig`,
#       `programs.terminalKit`, `llm-agents`, `my.hm.`, `my.nixos.`), the state and options
#       of a particular harness's own modules (`.pi/`, `.pi"`, `pi-web`, `pi-sessions`,
#       `CLAUDE_CONFIG_DIR`, `programs.pi`, a prefix of every `programs.pi*` namespace) or a
#       firewall setting (`networking.firewall`). A token with an owner is allowed in that
#       file only: `CLAUDE_CONFIG_DIR` in `modules/home-manager/bases.nix`, the claude base,
#       which gives the sandboxed Claude Code a config dir of its own;
#   (2) no non-comment line of a `.nix` file under `modules/` names the rendered directories
#       (`profiles/`, `shell/`, `services/`, `services-nono/`, `sysctl/`, `install/` at the
#       root: generated from the modules, never read by them). A relative path must resolve
#       inside the repository root but not into a rendered directory, and must not be the root
#       itself (a root path is how `../.. + "/profiles/x"` and `"${../..}/shell/x"` reach one);
#       a path that starts with `/` must have no `..` segment (appended to a path, it climbs
#       out of the module directory); the strings `"/<dir>`, `}/<dir>`, `"/..` and `}/..` are
#       refused outright. This also covers code that no evaluation reaches;
#   (3) the render evaluated from a copy of the repository without the rendered directories:
#       a module that reads a rendered file, however it builds the path (`dirOf`, string
#       concatenation), fails the evaluation of this check with "No such file or directory".
# Shell, not `builtins.match`: no regex over large text in Nix.
{
  pkgs,
  lib,
  home-manager,
  self,
}: let
  tokens = [
    "osConfig"
    "programs.terminalKit"
    "llm-agents"
    "my.hm."
    "my.nixos."
    ".pi/"
    ".pi\""
    "pi-web"
    "pi-sessions"
    "CLAUDE_CONFIG_DIR"
    "programs.pi"
    "networking.firewall"
  ];
  # token -> the one file that may name it
  owners = {
    CLAUDE_CONFIG_DIR = "modules/home-manager/bases.nix";
  };
  rendered = ["profiles" "shell" "services" "services-nono" "sysctl" "install"];

  # Rule (3): the source without the rendered directories, its modules as the render's `self`.
  root = ../.;
  bare = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.difference root (lib.fileset.unions (map (d: lib.fileset.maybeMissing (root + "/${d}")) rendered));
  };
  bareRender = import "${bare}/render" {
    inherit pkgs lib home-manager;
    self = {
      homeModules.default = import "${bare}/modules/home-manager";
      nixosModules.default = import "${bare}/modules/nixos";
    };
  };
  bareTree =
    builtins.addErrorContext "boundary: while evaluating the render from a copy without ${toString rendered} (a module reads a rendered file)"
    (builtins.unsafeDiscardStringContext bareRender.tree.drvPath);
in
  pkgs.runCommand "boundary" {nativeBuildInputs = [pkgs.gnugrep pkgs.coreutils pkgs.findutils];} ''
    echo "boundary: the render evaluates without the rendered directories: ${bareTree}"
    cd ${self}
    root=$(pwd)
    fail=0
    tokens=(${lib.concatMapStringsSep " " lib.escapeShellArg tokens})
    declare -A owner=(${lib.concatStringsSep " " (lib.mapAttrsToList (t: f: "[${lib.escapeShellArg t}]=${lib.escapeShellArg f}") owners)})
    rendered=(${lib.concatStringsSep " " rendered})
    while IFS= read -r file; do
      for t in "''${tokens[@]}"; do
        [ "''${owner[$t]-}" != "$file" ] || continue
        while IFS= read -r hit; do
          echo "boundary: $file:''${hit%%:*}: token '$t'" >&2
          fail=1
        done < <(grep -n -v '^[[:space:]]*#' "$file" | grep -F -- "$t" || true)
      done
    done < <(find modules packages -type f | sort)
    while IFS= read -r file; do
      dir=$(dirname "$file")
      while IFS= read -r numbered; do
        n=''${numbered%%:*}
        text=''${numbered#*:}
        for s in "\"/.." "}/.."; do
          case $text in
            *"$s"*)
              echo "boundary: $file:$n: the string '$s' climbs out of a path" >&2
              fail=1
              ;;
          esac
        done
        for r in "''${rendered[@]}"; do
          for s in "\"/$r" "}/$r"; do
            case $text in
              *"$s"*)
                echo "boundary: $file:$n: the string '$s' names the rendered directory $r/" >&2
                fail=1
                ;;
            esac
          done
        done
        for rel in $(printf '%s\n' "$text" | grep -oE '[A-Za-z0-9._/+-]*\.\.?/[A-Za-z0-9._/+-]*' || true); do
          case $rel in
            /*)
              case $rel/ in
                */../*)
                  echo "boundary: $file:$n: $rel starts with / and has a .. segment" >&2
                  fail=1
                  ;;
              esac
              continue
              ;;
          esac
          target=$(realpath -m "$dir/$rel")
          case $target in
            "$root")
              echo "boundary: $file:$n: $rel is the repository root" >&2
              fail=1
              ;;
            "$root"/*)
              for r in "''${rendered[@]}"; do
                case $target in
                  "$root/$r" | "$root/$r"/*)
                    echo "boundary: $file:$n: $rel is the rendered directory $r/" >&2
                    fail=1
                    ;;
                esac
              done
              ;;
            *)
              echo "boundary: $file:$n: $rel is outside the repository" >&2
              fail=1
              ;;
          esac
        done
      done < <(grep -n -v '^[[:space:]]*#' "$file" || true)
    done < <(find modules -type f -name '*.nix' | sort)
    [ "$fail" = 0 ] || exit 1
    touch $out
  ''
