# ai-sandbox-run [--x11] [--nono-alias NAME] [--open-urls-profile PROFILE] -- COMMAND [ARG...]
# Spec: docs/specs/2026-09-26-sandbox-namespace-isolation-design.md.
# Variables above this line are injected by sandbox-run.nix.

valid_tokens=("${all_layers[@]}" browser)

die() {
  local code=$1
  shift
  printf 'ai-sandbox-run: %s\n' "$*" >&2
  exit "$code"
}
has() {
  local x=$1 e
  shift
  for e in "$@"; do [ "$e" = "$x" ] && return 0; done
  return 1
}
under() {
  case $1 in "$2" | "$2"/*) return 0 ;; esac
  return 1
}

x11=0
nono_alias=
urls_profile=
while [ $# -gt 0 ]; do
  case $1 in
    --x11)
      x11=1
      shift
      ;;
    --nono-alias)
      [ $# -ge 2 ] || die 2 "--nono-alias needs a value"
      nono_alias=$2
      shift 2
      ;;
    --open-urls-profile)
      [ $# -ge 2 ] || die 2 "--open-urls-profile needs a value"
      urls_profile=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) die 2 "unknown option: $1" ;;
  esac
done
[ $# -gt 0 ] || die 2 "usage: ai-sandbox-run [--x11] [--nono-alias NAME] [--open-urls-profile PROFILE] -- COMMAND [ARG...]"

# --- relax (R8) --------------------------------------------------------------
relaxed=()
IFS=, read -ra toks <<<"${AI_SANDBOX_RELAX:-}"
for t in "${toks[@]}"; do
  [ -n "$t" ] || continue
  has "$t" "${valid_tokens[@]}" || die 2 "unknown token '$t' in AI_SANDBOX_RELAX; valid: ${valid_tokens[*]}"
  has "$t" "${relaxed[@]}" || relaxed+=("$t")
done
if [ ${#relaxed[@]} -gt 0 ]; then
  printf 'ai-sandbox-run: relaxed: %s\n' "$(
    IFS=,
    printf '%s' "${relaxed[*]}"
  )" >&2
fi
on() { has "$1" "${default_layers[@]}" && ! has "$1" "${relaxed[@]}"; }

case ${TMPDIR:-} in
  /*) ;;
  *) die 1 "TMPDIR must be an absolute path (got '${TMPDIR:-}')" ;;
esac
[ -d "$TMPDIR" ] || die 1 "TMPDIR is not a directory: $TMPDIR"
if has browser "${relaxed[@]}" && [ -z "$urls_profile" ]; then
  die 2 "AI_SANDBOX_RELAX=browser needs --open-urls-profile"
fi

uid=$("$coreutils/id" -u)
rt="$runtime_root/$uid"
args=(--dev-bind / / --unshare-user --die-with-parent)

# --- 1. namespaces -------------------------------------------------------------
if on userns; then args+=(--disable-userns); fi
if on pid; then args+=(--unshare-pid --proc /proc); fi

# --- 2. tmpfs layers -----------------------------------------------------------
if on session && [ -d "$rt" ]; then args+=(--tmpfs "$rt"); fi
if on tmp; then args+=(--tmpfs /tmp); fi

# --- 3. what must survive them, BEFORE any overlay below them (RF1, RF2) -------
survive() {
  if { on session && [ -d "$rt" ] && under "$1" "$rt"; } || { on tmp && under "$1" /tmp; }; then
    args+=(--bind "$1" "$1")
  fi
}
survive "$TMPDIR"
if [ "$PWD" != "$TMPDIR" ]; then survive "$PWD"; fi
if on tmp && [ "$x11" = 1 ] && [ -d /tmp/.X11-unix ]; then
  args+=(--ro-bind /tmp/.X11-unix /tmp/.X11-unix)
fi

# --- 4. read-only overlays -----------------------------------------------------
hide() {
  local s
  for s in "$@"; do
    if [ -S "$s" ]; then args+=(--ro-bind /dev/null "$s"); fi
  done
}
if on docker; then hide "${docker_sockets[@]}"; fi
if on system; then hide "${system_sockets[@]}"; fi

# Physical project root, set by git_ro: realpath resolves symlinks, so a
# logical $PWD through a symlink would never contain a resolved config path.
root=
# Read-only-bind $1 if it exists inside the project (not the project itself).
ro_in_tree() {
  if under "$1" "$root" && [ "$1" != "$root" ] && [ -e "$1" ]; then
    args+=(--ro-bind "$1" "$1")
    return 0
  fi
  return 1
}
# git's expansion of a path-valued config entry: `~/` is $HOME, a relative
# path is against $2.
config_path() {
  local v=$1
  case $v in
    /*) ;;
    \~/*) v=$HOME/${v#\~/} ;;
    *) v=$2/$v ;;
  esac
  "$coreutils/realpath" -m -- "$v"
}
# One config file alone, includes off, run from / so git discovers no
# repository: nothing in the repository's config is executed (spec D10, RF3).
cfg_get() { (cd / && "$git" config --file "$1" --no-includes -z "${@:2}"); }

git_ro() {
  root=$("$coreutils/pwd" -P)
  local gd=$root/.git p f v rec queue=() seen=()
  [ -d "$gd" ] || return 0
  for p in "$gd/hooks" "$gd/config" "$gd/config.worktree"; do
    if [ -e "$p" ]; then args+=(--ro-bind "$p" "$p"); fi
  done
  [ -f "$gd/config" ] || return 0
  # .git/config and every in-tree file it includes, transitively (T1.4b): an
  # agent-writable include could set core.fsmonitor or core.hooksPath for the
  # human's next git command. Out-of-tree includes are the user's own files.
  queue=("$gd/config")
  while [ ${#queue[@]} -gt 0 ] && [ ${#seen[@]} -lt 10 ]; do
    f=${queue[0]}
    queue=("${queue[@]:1}")
    if has "$f" "${seen[@]}"; then continue; fi
    seen+=("$f")
    # core.hooksPath is relative to the worktree root, not to the file.
    while IFS= read -r -d '' v; do
      ro_in_tree "$(config_path "$v" "$root")" || true
    done < <(cfg_get "$f" --get-all core.hooksPath || true)
    # -z: "key\nvalue\0"; includeIf conditions may contain spaces.
    while IFS= read -r -d '' rec; do
      p=$(config_path "${rec#*$'\n'}" "$("$coreutils/dirname" -- "$f")")
      if ro_in_tree "$p" && [ -f "$p" ]; then queue+=("$p"); fi
    done < <(cfg_get "$f" --get-regexp '^include(if\..*)?\.path$' || true)
  done
}
if on git; then git_ro; fi

# --- 4b. environment naming hidden paths ---------------------------------------
# SSH_AUTH_SOCK, DBUS_SESSION_BUS_ADDRESS, SWAYSOCK, NOTIFY_SOCKET, ... would
# point at sockets that do not exist inside. Unset them, so a tool reports
# "no agent"/"no bus" instead of a dangling path. Generic, not a list: any
# variable whose value is a path (or unix:path=) strictly below a tmpfs'd root
# and not below a survivor. The roots themselves (XDG_RUNTIME_DIR) are kept.
hidden_roots=()
if on session && [ -d "$rt" ]; then hidden_roots+=("$rt"); fi
if on tmp; then hidden_roots+=(/tmp); fi
survivors=("$TMPDIR" "$PWD")
if on tmp && [ "$x11" = 1 ]; then survivors+=(/tmp/.X11-unix); fi
if [ ${#hidden_roots[@]} -gt 0 ]; then
  while IFS= read -r -d '' kv; do
    name=${kv%%=*}
    val=${kv#*=}
    val=${val#unix:path=}
    val=${val%%[,;]*}
    case $val in /*) ;; *) continue ;; esac
    hidden=0
    for r in "${hidden_roots[@]}"; do
      case $val in "$r"/*) hidden=1 ;; esac
    done
    for s in "${survivors[@]}"; do
      if under "$val" "$s"; then hidden=0; fi
    done
    if [ "$hidden" = 1 ]; then args+=(--unsetenv "$name"); fi
  done < <("$coreutils/env" -0)
fi

args+=(--setenv PATH "$shim_bin:$PATH")

# --- 5. fail closed (R11) ------------------------------------------------------
if ! err=$("$bwrap" "${args[@]}" -- "$coreutils/true" 2>&1); then
  printf 'ai-sandbox-run: cannot build the isolation: %s\n' "$err" >&2
  if [ -n "$nono_alias" ]; then
    printf "ai-sandbox-run: run '%s' for a nono-only session\n" "$nono_alias" >&2
  fi
  exit 126
fi

if ! has browser "${relaxed[@]}"; then
  exec "$bwrap" "${args[@]}" -- "$@"
fi

# --- 6. URL relay (R12) -------------------------------------------------------
# Outside the isolation: a socat listener in TMPDIR (which survives into it)
# hands each URL to ai-sandbox-url-relay, which checks it against the
# profile's own open_urls and calls the real xdg-open. Not exec'd, so the
# relay can be cleaned up when the command exits (-d0: no "exiting on signal
# 15" warning at cleanup).
allow=$("$nono_bin" profile show "$urls_profile" --json |
  "$jq" -c '.open_urls // {allow_origins: [], allow_localhost: false}') ||
  die 1 "cannot resolve open_urls of profile '$urls_profile'"
relay_dir=$("$coreutils/mktemp" -d "$TMPDIR/ai-sandbox-url.XXXXXX")
sock=$relay_dir/url.sock
AI_SANDBOX_OPEN_URLS=$allow "$socat" -d0 "UNIX-LISTEN:$sock,fork,umask=0077" "EXEC:$url_relay" &
relay_pid=$!
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  kill "$relay_pid" 2>/dev/null || true
  wait "$relay_pid" 2>/dev/null || true
  rm -rf -- "$relay_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 143' TERM
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -S "$sock" ] && break
  "$coreutils/sleep" 0.1
done
[ -S "$sock" ] || die 1 "URL relay did not start"
rc=0
"$bwrap" "${args[@]}" --setenv AI_SANDBOX_URL_SOCK "$sock" -- "$@" || rc=$?
exit "$rc"
