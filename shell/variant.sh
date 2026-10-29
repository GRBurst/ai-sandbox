# shellcheck shell=bash
# Sourced by bash and zsh: the alias strings of the Nix module, without Nix.
#
# ai_sandbox_alias_string [--x11] [--tmp-leaf L] [--nono-alias N] [--nono-only] COMMAND PROFILE [NONO_ARG...]
#   Prints the string the module's alias builder produces, byte for byte:
#     TMPDIR="${TMPDIR:-<fallback>}/<L or COMMAND>/tmp" sh -c 'mkdir -p -m 700 "$TMPDIR" && exec
#     [ai-sandbox-run [--x11] [--nono-alias N] --open-urls-profile PROFILE --] nono run --profile PROFILE
#     <AI_SANDBOX_NONO_ARGS> <NONO_ARG...> -- COMMAND "$@"' COMMAND
#   --nono-only drops the wrapper (the `_nono` twin; every alias while the isolation is off).
#   Environment: AI_SANDBOX_NONO_ARGS (default --allow-cwd, used as given),
#   AI_SANDBOX_TMPDIR_FALLBACK (default /run/user/$UID, not expanded).
#   Exit 1: the fallback is relative, has a .. segment, or is "/", /tmp, /var/tmp, /run/lock,
#   /dev/shm or /run/user however it is spelled (trailing, repeated or . segments; the module refuses the
#   same values); 2: usage, or an unsafe value.
#   Every value is pasted into the alias's `sh -c '...'` body or its TMPDIR, so it is refused
#   (exit 2) unless it is made of letters, digits and _ . , : = + @ % / - only (the fallback
#   may also hold $, as in the default; AI_SANDBOX_NONO_ARGS is such words joined by single
#   blanks). COMMAND, L and N are names: no / or =, and not . or ..
# ai_sandbox_variant [--x11] ALIAS COMMAND PROFILE [NONO_ARG...]
#   Defines ALIAS (through the wrapper, with ALIAS_nono as its fallback hint) and ALIAS_nono.

# _ai_sandbox_safe CALLER arg|name|fallback VALUE: VALUE may be pasted into an alias (see
# above); otherwise say so on stderr and fail.
_ai_sandbox_safe() {
  case $2:$3 in
    arg: | name: | fallback: | *:*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.,:=+@%/\$-]* | \
      arg:*\$* | name:*\$* | name:. | name:.. | name:*/* | name:*=*)
      printf '%s: unsafe %s "%s": use letters, digits and _ . , : = + @ %% / - only (a fallback may hold $; a name holds no / or = and is not . or ..)\n' "$1" "$2" "$3" >&2
      return 1
      ;;
  esac
}

ai_sandbox_alias_string() {
  local x11=0 only=0 leaf="" nalias="" cmd prof fb na inner arg norm rest seg
  while [ $# -gt 0 ]; do
    case $1 in
      --x11) x11=1 ;;
      --nono-only) only=1 ;;
      --tmp-leaf | --nono-alias)
        if [ $# -lt 2 ]; then
          echo "ai_sandbox_alias_string: $1 needs a value" >&2
          return 2
        fi
        if [ "$1" = --tmp-leaf ]; then leaf=$2; else nalias=$2; fi
        shift
        ;;
      -*)
        echo "ai_sandbox_alias_string: unknown option $1" >&2
        return 2
        ;;
      *) break ;;
    esac
    shift
  done
  if [ $# -lt 2 ]; then
    echo "usage: ai_sandbox_alias_string [--x11] [--tmp-leaf L] [--nono-alias N] [--nono-only] COMMAND PROFILE [NONO_ARG...]" >&2
    return 2
  fi
  cmd=$1 prof=$2
  shift 2
  _ai_sandbox_safe ai_sandbox_alias_string name "$cmd" || return 2
  if [ -n "$leaf" ]; then _ai_sandbox_safe ai_sandbox_alias_string name "$leaf" || return 2; fi
  if [ -n "$nalias" ]; then _ai_sandbox_safe ai_sandbox_alias_string name "$nalias" || return 2; fi
  for arg in "$prof" "$@"; do
    _ai_sandbox_safe ai_sandbox_alias_string arg "$arg" || return 2
  done
  # shellcheck disable=SC2016
  fb=${AI_SANDBOX_TMPDIR_FALLBACK-'/run/user/$UID'}
  # The path the fallback names, compared as the module's guard compares it: empty and .
  # segments dropped (/tmp/, //tmp and /tmp/. are /tmp); a relative one, or one with a ..
  # segment (not resolvable without the filesystem), is refused outright.
  norm=/ rest=""
  case $fb in /*) norm="" rest=$fb/ ;; esac
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    rest=${rest#*/}
    case $seg in
      "" | .) ;;
      ..) norm=/ rest="" ;;
      *) norm=$norm/$seg ;;
    esac
  done
  case ${norm:-/} in
    / | /tmp | /var/tmp | /run/lock | /dev/shm | /run/user)
      echo "ai_sandbox_alias_string: AI_SANDBOX_TMPDIR_FALLBACK must be an absolute path without a .. segment that is not /, /tmp, /var/tmp, /run/lock, /dev/shm or /run/user, however it is spelled (trailing, repeated or . segments)" >&2
      return 1
      ;;
  esac
  _ai_sandbox_safe AI_SANDBOX_TMPDIR_FALLBACK fallback "$fb" || return 2
  na=${AI_SANDBOX_NONO_ARGS---allow-cwd}
  # Safe words joined by single blanks (a leading, trailing or double blank is an empty word).
  arg=$na
  case $arg in ' '* | *' ' | *'  '*) arg=" " ;; esac
  while [ -n "$arg" ]; do
    _ai_sandbox_safe AI_SANDBOX_NONO_ARGS arg "${arg%% *}" || return 2
    case $arg in *' '*) arg=${arg#* } ;; *) arg="" ;; esac
  done
  # shellcheck disable=SC2016
  inner='mkdir -p -m 700 "$TMPDIR" && exec'
  if [ "$only" = 0 ]; then
    inner="$inner ai-sandbox-run"
    if [ "$x11" = 1 ]; then inner="$inner --x11"; fi
    if [ -n "$nalias" ]; then inner="$inner --nono-alias $nalias"; fi
    inner="$inner --open-urls-profile $prof --"
  fi
  inner="$inner nono run --profile $prof"
  if [ -n "$na" ]; then inner="$inner $na"; fi
  for arg in "$@"; do inner="$inner $arg"; done
  printf '%s\n' "TMPDIR=\"\${TMPDIR:-$fb}/${leaf:-$cmd}/tmp\" sh -c '$inner -- $cmd \"\$@\"' $cmd"
}

ai_sandbox_variant() {
  local x11="" name cmd prof wrapped plain
  if [ "${1-}" = --x11 ]; then
    x11=--x11
    shift
  fi
  if [ $# -lt 3 ]; then
    echo "usage: ai_sandbox_variant [--x11] ALIAS COMMAND PROFILE [NONO_ARG...]" >&2
    return 2
  fi
  name=$1 cmd=$2 prof=$3
  shift 3
  _ai_sandbox_safe ai_sandbox_variant name "$name" || return 2
  if [ -n "$x11" ]; then
    wrapped=$(ai_sandbox_alias_string --x11 --nono-alias "${name}_nono" "$cmd" "$prof" "$@") || return
  else
    wrapped=$(ai_sandbox_alias_string --nono-alias "${name}_nono" "$cmd" "$prof" "$@") || return
  fi
  plain=$(ai_sandbox_alias_string --nono-only "$cmd" "$prof" "$@") || return
  # shellcheck disable=SC2139
  alias -- "$name=$wrapped"
  # shellcheck disable=SC2139
  alias -- "${name}_nono=$plain"
}
