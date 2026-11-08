#!/usr/bin/env bash
# Install or remove the ai-sandbox without Nix. Needs only bash, coreutils and
# the tools listed in scripts/deps; it never calls `nix` or `sudo` and never
# edits shell rc files. It pulls the nono registry packs the installed profiles
# extend when nono lacks them (`nono pull`, needs network access once).
#
# usage: scripts/install.sh [install|uninstall] [--layer NAME=DIR]...
#   env: PREFIX          install prefix (default ~/.local): an absolute path of
#                        letters, digits and . _ + @ - only
#        HARNESSES       comma-separated harnesses of install/harnesses.json whose
#                        profiles are installed (default claude,opencode,pi,agy)
#        GPU             1 (default) installs the GPU variants too, 0 does not
#        ISOLATION       1 (default) installs the isolation wrapper, 0 does not
#        SERVICES        comma- or blank-separated web-UI services of
#                        install/services.json to install (default none)
#        SERVICE_PATH    the PATH of the service units (default
#                        /usr/local/bin:/usr/bin:/bin): every entry must exist,
#                        not be writable by or owned by you, and not lie in
#                        the service's working tree or a read-write grant of its
#                        profile (nono --strict-broker-path refuses such a
#                        PATH), and it must hold the commands the units run;
#                        else the install is refused
#        PROXY_LISTEN    the address the services' proxies bind (default
#                        127.0.0.1: this machine only); 0.0.0.0 is every
#                        interface. An IPv4 or IPv6 address without brackets,
#                        zone or port, else a usage error
#        XDG_CONFIG_HOME the nono profiles go to its nono/profiles, the units to
#                        systemd/user, the Caddyfiles to agent-web (default
#                        ~/.config); absolute, of the characters of PREFIX
#        XDG_DATA_HOME   manifest and layer record (default ~/.local/share), absolute
#        XDG_CACHE_HOME  the per-command cache dirs of install/dirs (default
#                        ~/.cache); absolute, of the characters of PREFIX
#        AI_SANDBOX_DEFAULTS  defaults.json for the wrapper (default: the one in
#                        packages/ai-sandbox-run; the checks use fixtures)
#        An empty value is the default; an unset option and an empty one are the same.
#        HARNESSES, GPU, ISOLATION, SERVICES, SERVICE_PATH and PROXY_LISTEN are
#        recorded when set ($XDG_DATA_HOME/ai-sandbox/options, in the manifest):
#        an empty one takes its recorded value, so a plain reinstall repeats the
#        last install; the value `default` takes the default and drops the record.
#   --layer NAME=DIR     registers DIR (absolute, holding *.json nono profiles) as
#                        the layer NAME: its profiles are copied after the shipped
#                        ones, layers in registration order, the later wins. The
#                        registrations are recorded ($XDG_DATA_HOME/ai-sandbox/layers),
#                        so a plain reinstall reapplies them; registering NAME
#                        again changes its DIR, not its place.
#   exit: 0 done; 1 refused (missing tool, a target that is not ours and
#         differs, a PREFIX, XDG directory, manifest or layer it cannot trust,
#         a service that could not start, an enabled service unit it would
#         remove: disable it first, a nono pack it could not pull or list,
#         or could not remove on uninstall, which still removes the files);
#         2 usage (also an option value it does not know)
#
# The shell files go to $PREFIX/share/ai-sandbox/shell; the script prints the
# line that sources its aliases.sh and never edits an rc file. It prints the
# systemctl --user lines that start the services and the sudo lines of the
# kernel setting, and runs neither.
#
# Every file goes through `put`. A manifest ($XDG_DATA_HOME/ai-sandbox/manifest,
# one `sha256  path` line per file) records what was written; `uninstall`
# removes exactly those files (directories it created stay: they may hold data).
# Files are written and removed only under the `roots` directories; a manifest
# line that is not an absolute path under them refuses the whole run. The one
# exception is the nono packs (below): `nono pull` and `nono remove` write and
# undo their wiring in the agent configurations of your home.
#
# nono does not fetch a pack that a profile names in `extends` (NONO_AUTO_MIGRATE
# covers bare profile names only), so after every check and before the first
# file is written, each registry pack an installed profile extends, or an
# installed shipped base is made from (install/bases.json), that nono lacks is
# pulled at the version scripts/packs pins; a failed pull refuses the install.
# Pulled packs are recorded ($XDG_DATA_HOME/ai-sandbox/packs, one per line); `uninstall` removes exactly those (`nono remove`), never a pack nono
# had before. A kill between a pull and its record leaves that pack unrecorded:
# uninstall then keeps it (the README says so).
set -euo pipefail

# First, so that an older bash reaches this message (associative arrays below)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  printf 'ai-sandbox install: bash 4.4 or newer is needed (this is bash %s)\n' "$BASH_VERSION" >&2
  exit 1
fi

# an exported CDPATH would send the cd below elsewhere (and make it print)
unset CDPATH
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
: "${HOME:?HOME is not set}"
PREFIX=${PREFIX:-$HOME/.local}
PREFIX=${PREFIX%/}
# The options a run records ($XDG_DATA_HOME/ai-sandbox/options) and reuses while
# they are empty; `default` is the default and drops the record (apply_options).
# PREFIX and the XDG directories are not among them: they locate the install.
opt_names=(HARNESSES GPU ISOLATION SERVICES SERVICE_PATH PROXY_LISTEN)
declare -A opt_default=([HARNESSES]='claude,opencode,pi,agy' [GPU]=1 [ISOLATION]=1 [SERVICES]=''
  [SERVICE_PATH]=/usr/local/bin:/usr/bin:/bin [PROXY_LISTEN]=127.0.0.1)
declare -A opt_given=()    # option -> its value in the environment ('' when unset)
declare -A opt_recorded=() # option -> its value in the record of the last install
declare -A opt_kept=()     # option -> the value this run records
for _o in "${opt_names[@]}"; do opt_given[$_o]=${!_o-}; done
unset _o
# apply_options: each option from the environment, else from the record, else
# its default; the value `default` takes the default and is not recorded.
apply_options() {
  local n v
  opt_kept=()
  for n in "${opt_names[@]}"; do
    v=${opt_given[$n]}
    if [ "$v" = default ]; then
      v=
    elif [ -z "$v" ]; then
      v=${opt_recorded[$n]-}
    fi
    [ -z "$v" ] || opt_kept[$n]=$v
    printf -v "$n" '%s' "${v:-${opt_default[$n]}}"
  done
  # shellcheck disable=SC2153 # both set by the printf -v above
  service_path=$SERVICE_PATH proxy_listen=$PROXY_LISTEN
}
apply_options
data_home=${XDG_DATA_HOME:-$HOME/.local/share}
data_home=${data_home%/}
data_dir=$data_home/ai-sandbox
manifest=$data_dir/manifest
layers_file=$data_dir/layers
options_file=$data_dir/options
packs_file=$data_dir/packs
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
config_home=${config_home%/}
profile_dir=$config_home/nono/profiles
cache_home=${XDG_CACHE_HOME:-$HOME/.cache}
cache_home=${cache_home%/}
shell_dir=$PREFIX/share/ai-sandbox/shell
unit_dir=$config_home/systemd/user
web_dir=$config_home/agent-web
# The directories files are written under and removed from; a step that
# installs elsewhere adds its directory here.
roots=("$PREFIX" "$data_dir" "$profile_dir" "$unit_dir" "$web_dir")
AI_SANDBOX_DEFAULTS=${AI_SANDBOX_DEFAULTS:-$root/packages/ai-sandbox-run/defaults.json}
# bash 5.2 reads an ampersand in a replacement as the matched text; the values here are paths
shopt -u patsub_replacement 2>/dev/null || true
tmpdir=

declare -A tool=()          # binary -> absolute path, from scripts/deps
declare -A old_manifest=()  # path -> sha256 of the previous install
declare -A written=()       # path -> sha256 put by this run
declare -a new_layers=()    # NAME=DIR of the --layer options, in order
declare -a layer_names=()   # the registered layers, in registration order
declare -A layer_dirs=()    # layer name -> directory
declare -A profile_src=()   # profile file name -> the file copied to profile_dir
declare -a cache_dirs=()    # the directories of install/dirs, resolved
declare -a home_lines=()    # the lines of install/dirs below @HOME@ (a base's dir, then the base)
declare -a base_dirs=()     # those resolved, when their base is installed
declare -a services=()      # the services of SERVICES
declare -a service_profiles=() # their profiles
declare -a service_units=() # their unit files, for systemctl
declare -a service_dirs=()  # their data dirs, resolved
declare -a sysctl_lines=()  # the setting lines of sysctl/60-ai-sandbox.conf
declare -A service_files=() # unit or Caddyfile path -> its text with this install's values
declare -A pack_pin=()      # registry pack -> the version scripts/packs pins
declare -A pack_recorded=() # the packs the installer pulled (the record)
declare -A pack_installed=() # registry pack -> the version nono has installed
declare -A base_pack=()     # shipped base (install/bases.json) -> the registry pack it is made from
# a registry pack as nono reads one in `extends`: <namespace>/<name>[@<version>]
pack_re='^([A-Za-z0-9_][A-Za-z0-9._-]*/[A-Za-z0-9_-][A-Za-z0-9._-]*)(@[A-Za-z0-9._+-]+)?$'
staging=0                   # 1: put checks and queues, flush_puts writes
declare -a q_src=() q_dest=() q_mode=() q_hash=() # the queued puts
declare -A queued=()        # the destinations of the queued puts

say() { printf 'ai-sandbox install: %s\n' "$*"; }
warn() { printf 'ai-sandbox install: warning: %s\n' "$*" >&2; }
die() {
  printf 'ai-sandbox install: %s\n' "$*" >&2
  exit 1
}
usage() {
  printf 'usage: %s [install|uninstall] [--layer NAME=DIR]...\n' "${0##*/}" >&2
  exit 2
}
usage_error() {
  printf 'ai-sandbox install: %s\n' "$*" >&2
  exit 2
}

# plain_dir PATH: absolute, of letters, digits and . _ + @ - only (socat EXEC
# splits on blanks, commas, colons and quotes), no `.` or `..` segment, and no
# @NAME@ in it: a later substitution of that placeholder would rewrite a value
# that was already checked (a SERVICE_PATH entry, say).
plain_dir() {
  local re='@[A-Za-z_]+@'
  if [[ $1 =~ $re ]]; then
    printf 'ai-sandbox install: %s looks like a placeholder (@NAME@), which a later substitution would rewrite: %s\n' "${BASH_REMATCH[0]}" "$1" >&2
    return 1
  fi
  [[ $1 =~ ^(/[A-Za-z0-9._+@-]+)+$ && $1/ != */./* && $1/ != */../* ]]
}

# PREFIX and the data directory are checked before anything is written or
# removed: a relative one would name other files from another directory.
check_dirs() {
  plain_dir "$PREFIX" ||
    die "PREFIX must be an absolute path of letters, digits and . _ + @ - (no blanks, commas, colons or quotes: the URL relay is started through socat EXEC; no . or .. segment; write \$HOME, not ~): $PREFIX"
  plain_dir "$data_home" ||
    die "XDG_DATA_HOME must be an absolute path of letters, digits and . _ + @ - (no . or .. segment): $data_home"
  plain_dir "$config_home" ||
    die "XDG_CONFIG_HOME must be an absolute path of letters, digits and . _ + @ - (no . or .. segment): $config_home"
}

# The switches of an install; a value they do not know is a usage error (a
# typo must not turn the isolation off). Every option is one line: the record
# holds one per line.
check_options() {
  local n
  for n in "${opt_names[@]}"; do
    [[ ${!n} != *$'\n'* ]] || usage_error "$n must be a single line"
  done
  case $GPU in 0 | 1) ;; *) usage_error "GPU must be 0 or 1: $GPU" ;; esac
  case $ISOLATION in 0 | 1) ;; *) usage_error "ISOLATION must be 0 or 1: $ISOLATION" ;; esac
  is_ip "$proxy_listen" ||
    usage_error "PROXY_LISTEN must be an IPv4 or IPv6 address without brackets, zone or port (127.0.0.1, the default: this machine only; 0.0.0.0: every interface): $proxy_listen"
}

# is_ip VALUE: an IPv4 address (four decimal octets, no leading zero) or an IPv6
# one (one to four hex digits per group, at most one ::, no embedded IPv4); what
# the module accepts as proxy.listenAddress.
is_ip() {
  local a=$1 o='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])' list rest g n=0 compressed=0
  [[ ! $a =~ ^$o\.$o\.$o\.$o$ ]] || return 0
  [[ $a =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  list=$a
  if [[ $a == *::* ]]; then
    compressed=1
    local left=${a%%::*} right=${a#*::}
    [[ $right != *::* ]] || return 1
    list=$left${left:+${right:+:}}$right
  fi
  if [ -n "$list" ]; then
    rest=$list:
    while [ -n "$rest" ]; do
      g=${rest%%:*}
      rest=${rest#*:}
      [[ $g =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      n=$((n + 1))
    done
  fi
  if [ "$compressed" = 1 ]; then [ "$n" -le 7 ]; else [ "$n" = 8 ]; fi
}

# Every name in HARNESSES is a harness of install/harnesses.json.
check_harnesses() {
  local file=$root/install/harnesses.json h hs=()
  [[ ,$HARNESSES, != *,,* ]] || usage_error "HARNESSES: an empty name (a leading, trailing or doubled comma): $HARNESSES"
  IFS=, read -r -a hs <<<"$HARNESSES"
  for h in "${hs[@]}"; do
    jq -e --arg h "$h" 'has($h)' "$file" >/dev/null ||
      usage_error "HARNESSES: unknown harness '$h' (known: $(jq -r 'keys | join(",")' "$file"))"
  done
}

# managed_path PATH: absolute, no `.`, `..` or empty segment, under a root.
managed_path() {
  local r
  [[ $1 == /* && $1/ != */./* && $1/ != */../* && $1 != *//* ]] || return 1
  for r in "${roots[@]}"; do
    [[ $1 == "$r"/?* ]] && return 0
  done
  return 1
}

# The previous manifest into old_manifest: one `sha256  path` line per entry (a
# path may contain blanks). Every line is checked before any is used; one that
# is not a hash and a managed path refuses the run before anything is written
# or removed.
load_manifest() {
  local line n=0 hash path re='^([0-9a-f]{64})  (/.*)$'
  old_manifest=()
  [ -f "$manifest" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -n "$line" ] || continue
    hash='' path=''
    if [[ $line =~ $re ]]; then hash=${BASH_REMATCH[1]} path=${BASH_REMATCH[2]}; fi
    if [ -z "$hash" ] || ! managed_path "$path"; then
      die "$manifest:$n: not a \`sha256  path\` line with a path under ${roots[*]}; nothing was changed (files of an install with another PREFIX or XDG_CONFIG_HOME are removed with that PREFIX or XDG_CONFIG_HOME): $line"
    fi
    old_manifest[$path]=$hash
  done <"$manifest"
}

# load_options: the record of the last install's options into opt_recorded. A
# line that is not NAME=VALUE (a recorded option's NAME, a value) refuses the
# run before anything changes.
load_options() {
  local line n=0 re='^([A-Z_]+)=(.+)$'
  opt_recorded=()
  [ -f "$options_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -n "$line" ] || continue
    if ! [[ $line =~ $re ]] || [ -z "${opt_default[${BASH_REMATCH[1]}]+x}" ]; then
      die "$options_file:$n: not a NAME=VALUE line of an option the installer records (${opt_names[*]}); nothing was changed: $line"
    fi
    opt_recorded[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  done <"$options_file"
}

# reused_options: name the recorded options this run reuses.
reused_options() {
  local n list=()
  for n in "${opt_names[@]}"; do
    if [ -z "${opt_given[$n]}" ] && [ -n "${opt_recorded[$n]+x}" ]; then list+=("$n=${opt_recorded[$n]}"); fi
  done
  [ ${#list[@]} -eq 0 ] ||
    say "reusing the options of the last install ($options_file): ${list[*]} (set one to change it, to 'default' to drop it)"
}

# install_options: the record of the options this run was given or reused; none
# (every option at its default) writes no record.
install_options() {
  local n
  [ ${#opt_kept[@]} -gt 0 ] || return 0
  ensure_scratch
  for n in "${opt_names[@]}"; do
    [ -z "${opt_kept[$n]+x}" ] || printf '%s=%s\n' "$n" "${opt_kept[$n]}"
  done >"$tmpdir/options"
  put "$tmpdir/options" "$options_file" 0644
}

# resolve_deps: every tool of scripts/deps that applies to this run must be on
# PATH; all missing ones are listed together and nothing is written.
resolve_deps() {
  local line bin pkg when path missing=()
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | '#'*) continue ;; esac
    read -r bin pkg when <<<"$line"
    case $when in
      always) ;;
      isolation) [ "$ISOLATION" = 1 ] || continue ;;
      services) [ -n "$SERVICES" ] || continue ;;
      optional)
        if path=$(command -v "$bin"); then
          tool[$bin]=$path
        else
          warn "optional tool $bin ($pkg) not found; what needs it will not work"
        fi
        continue
        ;;
      *) die "scripts/deps: cannot read the line: $line" ;;
    esac
    if path=$(command -v "$bin"); then
      tool[$bin]=$path
    else
      missing+=("$bin ($pkg)")
    fi
  done <"$root/scripts/deps"
  [ ${#missing[@]} -eq 0 ] || die "missing tools, install them and retry: ${missing[*]}"
  check_nono_version
}

# profiles/NONO_VERSION is the nono the profiles were rendered against; an
# older nono may not know every key. A warning only.
check_nono_version() {
  local file=$root/profiles/NONO_VERSION want have out
  [ -f "$file" ] || return 0
  want=$(<"$file")
  out=$("${tool[nono]}" --version 2>/dev/null) || {
    warn "could not run nono --version"
    return 0
  }
  [[ $out =~ [0-9]+(\.[0-9]+)+ ]] || {
    warn "cannot read the nono version from: $out"
    return 0
  }
  have=${BASH_REMATCH[0]}
  if [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n 1)" != "$want" ]; then
    warn "nono $have is older than $want, which the profiles were rendered against"
  fi
}

# put SRC DEST MODE: install SRC as DEST. An existing DEST that this installer
# did not write (not in the previous manifest) and that differs is never
# overwritten, and a directory is not written into. While `staging` is 1 the
# checks run and the write is queued (flush_puts), so a refusal comes before the
# first file is written.
put() {
  local src=$1 dest=$2 mode=$3 hash b
  managed_path "$dest" || die "refusing to write $dest: it is not under ${roots[*]}"
  b=$(blocked_dir "${dest%/*}")
  [ -z "$b" ] || die "refusing to write $dest: $b is not a directory you can write"
  hash=$(sha256sum <"$src")
  hash=${hash%% *}
  if [ -d "$dest" ] && [ ! -L "$dest" ]; then die "refusing to write $dest: it is a directory"; fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ -z "${old_manifest[$dest]+x}" ] && [ "$(sha256sum <"$dest" 2>/dev/null || true)" != "$hash  -" ]; then
      die "refusing to overwrite $dest: it exists, was not installed by this script and differs"
    fi
  fi
  if [ "$staging" = 1 ]; then
    q_src+=("$src") q_dest+=("$dest") q_mode+=("$mode") q_hash+=("$hash")
    queued[$dest]=1
    return 0
  fi
  install -D -T -m "$mode" -- "$src" "$dest"
  written[$dest]=$hash
}

# blocked_dir DIR: what keeps DIR from being made, or written into: DIR, or
# its deepest ancestor that exists, when that is not a directory you can
# write. Prints nothing when DIR is fine.
blocked_dir() {
  local d=$1
  while [ ! -e "$d" ] && [ ! -L "$d" ]; do
    d=${d%/*}
    d=${d:-/}
  done
  if [ ! -d "$d" ] || [ ! -w "$d" ] || [ ! -x "$d" ]; then printf '%s' "$d"; fi
}

# check_make_dirs: every cache and data dir is a directory of yours (install
# -d -m 0700 sets its mode) or can be made, and the manifest's directory can
# be written; checked while staging, so a refusal comes before the first write.
check_make_dirs() {
  local d b
  # nono resolves a symlink when it takes the grant: a linked ~/.claude-sandbox
  # would hand its target (~/.claude, say) to every claude session.
  for d in "${base_dirs[@]}"; do
    [ ! -L "$d" ] || die "$d is a symbolic link; make it a directory of its own (copy what you need into it, never link it): the sandbox would get read and write on the link's target"
  done
  for d in "${cache_dirs[@]}" "${service_dirs[@]}"; do
    if [ -e "$d" ] || [ -L "$d" ]; then
      { [ -d "$d" ] && [ -O "$d" ]; } || die "cannot make the directory $d 0700: it exists and is not a directory of yours"
    else
      b=$(blocked_dir "$d")
      [ -z "$b" ] || die "cannot make the directory $d: $b is not a directory you can write"
    fi
  done
  b=$(blocked_dir "$data_dir")
  [ -z "$b" ] || die "cannot write the manifest $manifest: $b is not a directory you can write"
}

# flush_puts: write what the staged puts queued.
flush_puts() {
  local i
  staging=0
  for i in "${!q_dest[@]}"; do
    install -D -T -m "${q_mode[$i]}" -- "${q_src[$i]}" "${q_dest[$i]}"
    written[${q_dest[$i]}]=${q_hash[$i]}
  done
}

# The manifest of this run. Partial (after a failure): the files of the
# previous manifest that this run did not rewrite stay listed.
write_manifest() {
  local mode=${1:-final} p tmp
  mkdir -p "$(dirname "$manifest")"
  tmp=$(mktemp "$manifest.XXXXXX")
  {
    for p in "${!written[@]}"; do printf '%s  %s\n' "${written[$p]}" "$p"; done
    if [ "$mode" = partial ]; then
      for p in "${!old_manifest[@]}"; do
        [ -n "${written[$p]+x}" ] || printf '%s  %s\n' "${old_manifest[$p]}" "$p"
      done
    fi
  } | LC_ALL=C sort >"$tmp"
  mv -f -- "$tmp" "$manifest"
}

# enabled_link PATH: for a unit file under the user unit directory, the link
# `systemctl --user enable` made to it (a *.wants or *.requires entry, also
# under $XDG_RUNTIME_DIR/systemd/user for `enable --runtime`), if any.
enabled_link() {
  local l rt=${XDG_RUNTIME_DIR:-/run/user/$EUID}/systemd/user
  [[ $1 == "$unit_dir"/*.service ]] || return 1
  for l in "$unit_dir"/*.wants/"${1##*/}" "$unit_dir"/*.requires/"${1##*/}" \
    "$rt"/*.wants/"${1##*/}" "$rt"/*.requires/"${1##*/}"; do
    if [ -e "$l" ] || [ -L "$l" ]; then
      printf '%s' "$l"
      return 0
    fi
  done
  return 1
}

# check_removable install|uninstall PATH...: refuse, before anything is changed,
# to remove the file of a unit that is enabled: it would go on running with its
# file gone and a dangling link. The test is on the files only (a unit started
# by hand shows nothing there). An install names the SERVICES that keep them.
check_removable() {
  local mode=$1 p l units=() links=() sorted=() keep=
  shift
  mapfile -t sorted < <(printf '%s\n' "$@" | LC_ALL=C sort)
  for p in "${sorted[@]}"; do
    if l=$(enabled_link "$p"); then
      units+=("${p##*/}")
      links+=("$l")
    fi
  done
  [ ${#units[@]} -gt 0 ] || return 0
  [ "$mode" != install ] || keep=$(keep_services "${units[@]}")
  [ -z "$keep" ] ||
    die "refusing to remove the unit(s) ${units[*]}: enabled (${links[*]}), and this run does not install them; to keep them, run again with SERVICES=$keep; to remove them, stop and disable them first, then run this again: systemctl --user disable --now ${units[*]}"
  die "refusing to remove the unit(s) ${units[*]}: enabled (${links[*]}). Stop and disable them first, then run this again: systemctl --user disable --now ${units[*]}"
}

# keep_services UNIT...: the services of this run and those of
# install/services.json that own a UNIT, comma-separated; empty when no UNIT
# has an owner there that this run leaves out.
keep_services() {
  local u s list=("${services[@]}") found=
  for u in "$@"; do
    while IFS= read -r s; do
      if [[ " ${list[*]} " != *" $s "* ]]; then list+=("$s") found=1; fi
    done < <(jq -r --arg u "${u%.service}" 'to_entries[] | select((.value.units // []) | index($u)) | .key' \
      "$root/install/services.json" 2>/dev/null)
  done
  [ -n "$found" ] || return 0
  local IFS=,
  printf '%s' "${list[*]}"
}

# Files of the previous install that this run did not write are stale.
remove_stale() {
  local p
  for p in "${!old_manifest[@]}"; do
    [ -z "${written[$p]+x}" ] || continue
    remove_managed "$p" "${old_manifest[$p]}" || warn "could not remove the stale file $p"
  done
}

# remove_managed PATH SHA256: remove a file of the manifest; one that changed
# since the install is removed too, with a warning.
remove_managed() {
  local have
  if [ -f "$1" ]; then
    have=$(sha256sum <"$1")
    [ "${have%% *}" = "$2" ] || warn "$1 changed since the install; removing it anyway"
  fi
  rm -f -- "$1"
}

# The tools sandbox-run.sh calls as $coreutils/<tool>, one per line.
coreutils_tools() {
  local line
  while IFS= read -r line; do
    while [[ $line =~ \$coreutils/([A-Za-z0-9_-]+)(.*)$ ]]; do
      printf '%s\n' "${BASH_REMATCH[1]}"
      line=${BASH_REMATCH[2]}
    done
  done <"$1"
}

# ensure_scratch: $tmpdir is a scratch directory, removed when the script
# exits. Call it directly, not in a command substitution: a subshell's
# assignment would not reach the exit handler.
ensure_scratch() {
  [ -n "$tmpdir" ] || tmpdir=$(mktemp -d)
}

# check_defaults FILE: FILE is a wrapper defaults file; its lists may be empty.
check_defaults() {
  jq -e '(.layers | type == "array" and all(type == "string"))
    and (.runtimeRoot | type == "string")
    and (.sockets.docker | type == "array" and all(type == "string"))
    and (.sockets.system | type == "array" and all(type == "string"))' "$1" >/dev/null 2>&1 ||
    die "$1: not a wrapper defaults file (want {\"layers\": [string], \"runtimeRoot\": string, \"sockets\": {\"docker\": [string], \"system\": [string]}}; lists may be empty)"
}

# The lines of stdin as shell words, blank-separated.
quoted_lines() {
  local line out=()
  while IFS= read -r line; do out+=("$(printf '%q' "$line")"); done
  local IFS=' '
  printf '%s' "${out[*]}"
}

# fill TEMPLATE NAME=VALUE...: the template with each at-sign-delimited NAME
# replaced by VALUE; a placeholder without a value is an error.
fill() {
  local tpl=$1 text kv
  text=$(<"$tpl")
  shift
  for kv in "$@"; do
    if [[ ${kv#*=} =~ @[A-Za-z_]+@ ]]; then die "${tpl##*/}: the value of ${kv%%=*}, ${kv#*=}, looks like a placeholder (${BASH_REMATCH[0]}), which a later substitution would rewrite"; fi
  done
  for kv in "$@"; do text=${text//"@${kv%%=*}@"/${kv#*=}}; done
  if [[ $text =~ @[A-Za-z_]+@ ]]; then die "${tpl##*/}: no value for the placeholder ${BASH_REMATCH[0]}"; fi
  printf '%s\n' "$text"
}

script_head() { printf '#!/usr/bin/env bash\nset -euo pipefail\n'; }

# path_line DIR...: a line that puts the (quoted) directories first on PATH.
path_line() {
  local dirs='' d
  for d in "$@"; do dirs+=$(printf '%q:' "$d"); done
  printf 'export PATH=%s\n' "${dirs}\$PATH"
}

# With the isolation on, bubblewrap must be able to build a user namespace
# here; distributions that restrict them fail now, not at the first run.
preflight() {
  local msg
  [ "$ISOLATION" = 1 ] || return 0
  msg=$("${tool[bwrap]}" --unshare-user --ro-bind / / -- true 2>&1) ||
    die "bubblewrap cannot create a user namespace here (${msg:-no message}); the isolation needs one. Allow unprivileged user namespaces, or install with ISOLATION=0"
}

# bin/ai-sandbox-run is the shebang, the preamble with the install-time values
# and sandbox-run.sh verbatim; the URL relay's helpers go to libexec with a PATH
# line where the Nix build has runtime inputs.
install_wrapper() {
  [ "$ISOLATION" = 1 ] || return 0
  local src=$root/packages/ai-sandbox-run libexec=$PREFIX/libexec/ai-sandbox d
  local all dflt docker system rt xdg_open
  check_defaults "$src/defaults.json"
  check_defaults "$AI_SANDBOX_DEFAULTS"
  # the wrapper calls coreutils from one directory: the one of cat must hold
  # them all (without merged /usr, /bin may lack some)
  local coreutils t missing=()
  coreutils=$(dirname -- "$(command -v cat)")
  while IFS= read -r t; do
    [ -x "$coreutils/$t" ] || missing+=("$t")
  done < <(coreutils_tools "$src/sandbox-run.sh")
  [ ${#missing[@]} -eq 0 ] ||
    die "the wrapper calls coreutils from the directory of cat, $coreutils, which lacks: ${missing[*]}; put a directory with all of GNU coreutils first on PATH"
  ensure_scratch
  d=$tmpdir
  all=$(jq -r '.layers[]' "$src/defaults.json" | quoted_lines)
  dflt=$(jq -r '.layers[]' "$AI_SANDBOX_DEFAULTS" | quoted_lines)
  docker=$(jq -r '.sockets.docker[]' "$AI_SANDBOX_DEFAULTS" | quoted_lines)
  system=$(jq -r '.sockets.system[]' "$AI_SANDBOX_DEFAULTS" | quoted_lines)
  rt=$(jq -r '.runtimeRoot' "$AI_SANDBOX_DEFAULTS")
  rt=$(printf '%q' "$rt")
  xdg_open=${tool[xdg-open]:-xdg-open}
  {
    script_head
    fill "$src/portable-preamble.sh" "all_layers=$all" "default_layers=$dflt" \
      "docker_sockets=$docker" "system_sockets=$system" "runtime_root=$rt" \
      "libexec=$(printf '%q' "$libexec")" "bwrap=$(printf '%q' "${tool[bwrap]}")" \
      "socat=$(printf '%q' "${tool[socat]}")" "jq=$(printf '%q' "${tool[jq]}")" \
      "git=$(printf '%q' "${tool[git]}")" "nono=$(printf '%q' "${tool[nono]}")" \
      "coreutils=$(printf '%q' "$coreutils")"
    cat "$src/sandbox-run.sh"
  } >"$d/ai-sandbox-run"
  put "$d/ai-sandbox-run" "$PREFIX/bin/ai-sandbox-run" 0755
  { script_head; path_line "$(dirname -- "${tool[socat]}")"; cat "$src/sandbox-xdg-open.sh"; } >"$d/xdg-open"
  put "$d/xdg-open" "$libexec/shim/xdg-open" 0755
  { script_head; path_line "$(dirname -- "${tool[jq]}")"; cat "$src/sandbox-url-check.sh"; } >"$d/ai-sandbox-url-check"
  put "$d/ai-sandbox-url-check" "$libexec/ai-sandbox-url-check" 0755
  {
    script_head
    path_line "$libexec" "$(dirname -- "${tool[setsid]}")"
    printf 'xdg_open=%q\n' "$xdg_open"
    cat "$src/sandbox-url-relay.sh"
  } >"$d/ai-sandbox-url-relay"
  put "$d/ai-sandbox-url-relay" "$libexec/ai-sandbox-url-relay" 0755
}

# selected FIELD: the FIELD (profile, aliases) of the selected harnesses, one per
# line: each harness's own and its variants', a GPU variant's only with GPU=1.
selected() {
  jq -r --arg f "$1" --arg hs "$HARNESSES" --argjson gpu "$GPU" '. as $all | $hs | split(",")[] | $all[.]
    | .[$f], (.variants[] | select(.gpu != true or $gpu == 1) | .[$f])' \
    "$root/install/harnesses.json"
}

# install_profiles: the shipped profiles of the selected harnesses into
# profile_src (copied by copy_profiles).
install_profiles() {
  local names n
  names=$(selected profile)
  while IFS= read -r n; do
    [[ $n =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "install/harnesses.json: not a profile name: $n"
    [ -f "$root/profiles/$n.json" ] || die "profiles/$n.json is missing (install/harnesses.json names it)"
    profile_src[$n.json]=$root/profiles/$n.json
  done <<<"$names"
  for n in "${service_profiles[@]}"; do profile_src[$n.json]=$root/profiles/$n.json; done
}

# add_layer NAME=DIR WHERE: register a layer; a name registered before keeps its
# place and takes the new directory.
add_layer() {
  local name=${1%%=*} dir=${1#*=}
  [[ $1 == *=* && $name =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
    die "$2: a layer is NAME=DIR with a NAME of letters, digits and _ . -: $1"
  [ -n "${layer_dirs[$name]+x}" ] || layer_names+=("$name")
  layer_dirs[$name]=$dir
}

# check_layer NAME DIR: DIR is an absolute directory of JSON profiles with plain
# file names.
check_layer() {
  local name=$1 dir=$2 f any=
  [[ $dir == /* && $dir != *$'\n'* ]] || die "layer $name: the directory must be an absolute path: $dir"
  [ -d "$dir" ] || die "layer $name: $dir is not a directory (register the layer again: --layer $name=DIR)"
  for f in "$dir"/*.json; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    any=1
    [[ ${f##*/} =~ ^[A-Za-z0-9][A-Za-z0-9._+@-]*\.json$ ]] || die "layer $name: not a plain profile file name: $f"
    { [ -f "$f" ] && jq -e 'type == "object"' "$f" >/dev/null 2>&1; } || die "layer $name: not a JSON object: $f"
  done
  [ -n "$any" ] || die "layer $name: $dir holds no *.json profile"
}

# profile_file NAME: the file installed as NAME.json: the last registered
# layer's that has one, else the shipped one.
profile_file() {
  local f=$root/profiles/$1.json name
  for name in "${layer_names[@]}"; do
    if [ -f "${layer_dirs[$name]}/$1.json" ]; then f=${layer_dirs[$name]}/$1.json; fi
  done
  printf '%s' "$f"
}

# The recorded layers, then those of the --layer options; every one is checked
# before anything is written.
load_layers() {
  local line n=0 spec name
  if [ -f "$layers_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      [ -z "$line" ] || add_layer "$line" "$layers_file:$n"
    done <"$layers_file"
  fi
  for spec in "${new_layers[@]}"; do add_layer "$spec" "--layer"; done
  for name in "${layer_names[@]}"; do check_layer "$name" "${layer_dirs[$name]}"; done
}

# load_bases: install/bases.json (a shipped base -> the registry pack it is made
# from) into base_pack; anything else, or a base profiles/ lacks, refuses the run
# before anything changes.
load_bases() {
  local file=$root/install/bases.json list b p
  base_pack=()
  list=$(jq -r 'if type == "object" and all(.[]; type == "string") then to_entries[] | "\(.key) \(.value)" else error("not an object of strings") end' "$file" 2>/dev/null) ||
    die "install/bases.json is not a JSON object of base names to registry packs"
  while read -r b p; do
    [ -n "$b" ] || continue
    [[ $b =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $p =~ $pack_re && -z ${BASH_REMATCH[2]} ]] ||
      die "install/bases.json: not a base name mapped to a <namespace>/<pack>: $b $p"
    [ -f "$root/profiles/$b.json" ] || die "profiles/$b.json is missing (install/bases.json names it)"
    base_pack[$b]=$p
  done <<<"$list"
}

# install_bases: the shipped base of every profile in profile_src that extends
# one (a layer's file of that name wins: it is there already).
install_bases() {
  local f ref
  for f in "${!profile_src[@]}"; do
    while IFS= read -r ref; do
      if [ -n "${base_pack[$ref]+x}" ] && [ -z "${profile_src[$ref.json]+x}" ]; then
        profile_src[$ref.json]=$root/profiles/$ref.json
      fi
    done < <(jq -r '.extends | if type == "array" then .[] else . end | strings' "${profile_src[$f]}")
  done
}

# install_layers: every layer's profiles over the shipped ones, in registration
# order (the later wins), and the record of the layers.
install_layers() {
  local name f
  for name in "${layer_names[@]}"; do
    for f in "${layer_dirs[$name]}"/*.json; do profile_src[${f##*/}]=$f; done
  done
  [ ${#layer_names[@]} -gt 0 ] || return 0
  ensure_scratch
  for name in "${layer_names[@]}"; do printf '%s=%s\n' "$name" "${layer_dirs[$name]}"; done >"$tmpdir/layers"
  put "$tmpdir/layers" "$layers_file" 0644
}

# Copies (not links: nono may rewrite a profile under NONO_AUTO_MIGRATE; a
# reinstall takes it back) of the chosen profiles into profile_dir.
copy_profiles() {
  local f
  for f in "${!profile_src[@]}"; do put "${profile_src[$f]}" "$profile_dir/$f" 0644; done
}

# load_pins: scripts/packs into pack_pin; a line that is not `<pack> <version>`
# refuses the run before anything changes.
load_pins() {
  local file=$root/scripts/packs line n=0 p v extra
  pack_pin=()
  [ -f "$file" ] || die "scripts/packs is missing"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    read -r p v extra <<<"$line" || true
    case $p in '' | '#'*) continue ;; esac
    [[ $p =~ $pack_re && -z ${BASH_REMATCH[2]} && $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -z $extra ]] ||
      die "scripts/packs:$n: not a \`<namespace>/<pack> <version>\` line: $line"
    pack_pin[$p]=$v
  done <"$file"
}

# load_pack_record: the record of the packs the installer pulled into
# pack_recorded; a line that is not a pack refuses the run before anything changes.
load_pack_record() {
  local line n=0
  pack_recorded=()
  [ -f "$packs_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -n "$line" ] || continue
    [[ $line =~ $pack_re && -z ${BASH_REMATCH[2]} ]] ||
      die "$packs_file:$n: not a <namespace>/<pack> line of a nono pack the installer pulled; nothing was changed: $line"
    pack_recorded[$line]=1
  done <"$packs_file"
}

# write_pack_record: pack_recorded into the record, sorted; none, no record.
write_pack_record() {
  local tmp
  if [ ${#pack_recorded[@]} -eq 0 ]; then
    rm -f -- "$packs_file"
    return 0
  fi
  mkdir -p -- "$data_dir"
  tmp=$(mktemp "$packs_file.XXXXXX")
  printf '%s\n' "${!pack_recorded[@]}" | LC_ALL=C sort >"$tmp"
  mv -f -- "$tmp" "$packs_file"
}

# installed_packs NONO: the packs nono has installed into pack_installed (pack ->
# version), from `nono list --installed --json`; fails when that fails.
installed_packs() {
  local out list p v
  pack_installed=()
  out=$("$1" list --installed --json </dev/null) || return 1
  list=$(jq -r '(.packages // {}) | if type == "object" then to_entries[] | "\(.key) \(.value.version)" else error("packages is not an object") end' <<<"$out") || return 1
  while read -r p v; do
    [ -z "$p" ] || pack_installed[$p]=$v
  done <<<"$list"
}

# install_packs: every registry pack an installed profile extends must be in
# nono's pack store before the first run. A missing one that scripts/packs pins
# is pulled at that version (nono checks its signature) and recorded at once,
# so uninstall finds it even when a later pull fails; one nono has, at any
# version, is left as it is; a missing one without a pin (a layer's) gets a
# warning. Runs after every check and before the first file is written: a
# failed pull (offline) refuses the install.
install_packs() {
  local f ref key pin refs=()
  local -A need=()
  for f in "${!profile_src[@]}"; do
    while IFS= read -r ref; do
      if [[ $ref =~ $pack_re && $ref != *.json ]]; then need[$ref]=$f; fi
    done < <(jq -r '.extends | if type == "array" then .[] else . end | strings' "${profile_src[$f]}")
    if [ -n "${base_pack[${f%.json}]+x}" ]; then need[${base_pack[${f%.json}]}]=$f; fi
  done
  [ ${#need[@]} -gt 0 ] || return 0
  installed_packs "${tool[nono]}" ||
    die "cannot read the packs nono has installed (nono list --installed --json failed); nothing was changed"
  mapfile -t refs < <(printf '%s\n' "${!need[@]}" | LC_ALL=C sort)
  for ref in "${refs[@]}"; do
    [[ $ref =~ $pack_re ]]
    key=${BASH_REMATCH[1]} pin=${pack_pin[${BASH_REMATCH[1]}]-}
    if [ -n "${pack_installed[$key]+x}" ]; then
      if [ -n "$pin" ] && [ "${pack_installed[$key]}" != "$pin" ]; then
        warn "the nono pack $key is at ${pack_installed[$key]}, not at $pin as scripts/packs pins; left as it is"
      fi
    elif [ -n "$pin" ]; then
      say "pulling the nono pack $key@$pin (${need[$ref]} needs it)"
      "${tool[nono]}" pull "$key@$pin" </dev/null ||
        die "could not pull the nono pack $key@$pin (see nono's message above; offline?); the install stopped before its first file. When online, run nono pull $key@$pin, or install again"
      pack_installed[$key]=$pin
      pack_recorded[$key]=1
      write_pack_record
    else
      warn "${need[$ref]} extends the nono pack $ref, which nono lacks and scripts/packs does not pin; pull it yourself: nono pull $ref"
    fi
  done
}

# remove_packs: `nono remove` (which undoes the pack's wiring) for every pack of
# the record. A pack nono no longer has leaves the record; one it cannot remove
# (or no nono on PATH) stays there, and the line that removes it is printed.
remove_packs() {
  local nono p listed=0 recorded=() left=()
  [ ${#pack_recorded[@]} -gt 0 ] || return 0
  nono=$(command -v nono) || nono=
  if [ -n "$nono" ] && installed_packs "$nono"; then listed=1; fi
  mapfile -t recorded < <(printf '%s\n' "${!pack_recorded[@]}" | LC_ALL=C sort)
  for p in "${recorded[@]}"; do
    if [ "$listed" = 1 ] && [ -z "${pack_installed[$p]+x}" ]; then
      unset "pack_recorded[$p]"
    elif [ -n "$nono" ] && "$nono" remove "$p" </dev/null; then
      say "removed the nono pack $p"
      unset "pack_recorded[$p]"
    else
      left+=("$p")
    fi
  done
  write_pack_record
  [ ${#left[@]} -eq 0 ] && return 0
  warn "could not remove the nono pack(s) the install pulled (${nono:-no nono on PATH}); they stay in $packs_file. Remove them with:"
  printf '  nono remove %s\n' "${left[@]}" >&2
  return 1
}

# install_shell: aliases.sh (its @SHELL_DIR@ the installed directory), variant.sh
# and the alias files of the selected harnesses and variants, from aliases.d
# with the isolation on, from aliases-nono.d with it off. No rc file is edited.
install_shell() {
  local src=$root/shell/aliases.d names f
  [ "$ISOLATION" = 1 ] || src=$root/shell/aliases-nono.d
  names=$(selected aliases)
  ensure_scratch
  fill "$root/shell/aliases.sh" "SHELL_DIR=$shell_dir" >"$tmpdir/aliases.sh"
  put "$tmpdir/aliases.sh" "$shell_dir/aliases.sh" 0644
  put "$root/shell/variant.sh" "$shell_dir/variant.sh" 0644
  while IFS= read -r f; do
    [[ $f =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.sh$ ]] || die "install/harnesses.json: not an alias file name: $f"
    [ -f "$src/$f" ] || die "${src#"$root"/}/$f is missing (install/harnesses.json names it)"
    put "$src/$f" "$shell_dir/aliases.d/$f" 0644
  done <<<"00-session.sh"$'\n'"$names"
}

# resolve VALUE: VALUE with @HOME@ and the XDG placeholders (and a leading
# $HOME/, the module's spelling of a data dir) replaced by this install's
# directories.
resolve() {
  local v=$1
  # shellcheck disable=SC2016 # a literal $HOME
  [[ $v != '$HOME/'* ]] || v=@HOME@/${v#'$HOME/'}
  v=${v//"@XDG_CACHE_HOME@"/$cache_home}
  v=${v//"@XDG_CONFIG_HOME@"/$config_home}
  v=${v//"@HOME@"/$HOME}
  printf '%s' "$v"
}

# load_dirs: the directories of install/dirs (the per-command cache dirs, the
# bases' config dirs) with the placeholders resolved, checked before anything
# is written. The cache dirs are made whatever HARNESSES selects; a line below
# @HOME@ is a shipped base's dir followed by that base (install/bases.json),
# which add_base_dirs takes once install_bases knows whether the base is
# installed.
load_dirs() {
  local line d b extra n=0
  plain_dir "$cache_home" ||
    die "XDG_CACHE_HOME must be an absolute path of letters, digits and . _ + @ - (no . or .. segment): $cache_home"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -n "$line" ] || continue
    case $line in
      @HOME@/*)
        read -r d b extra <<<"$line"
        { [ -n "$b" ] && [ -z "$extra" ] && [ -n "${base_pack[$b]+x}" ]; } ||
          die "install/dirs:$n: a directory below @HOME@ must be followed by its base of install/bases.json: $line"
        home_lines+=("$line")
        continue
        ;;
    esac
    d=$(resolve "$line")
    plain_dir "$d" || die "install/dirs:$n: not an absolute plain path once resolved: $line"
    cache_dirs+=("$d")
  done <"$root/install/dirs"
}

# add_base_dirs: the @HOME@ lines of install/dirs, each made (and a plain HOME
# required) only when its base is installed; run after install_bases.
add_base_dirs() {
  local b line d
  for line in "${home_lines[@]}"; do
    read -r line b <<<"$line"
    [ -n "${profile_src[$b.json]+x}" ] || continue
    plain_dir "$HOME" ||
      die "HOME must be an absolute path of letters, digits and . _ + @ - (no . or .. segment) for the directory $line of install/dirs: $HOME"
    d=$(resolve "$line")
    plain_dir "$d" || die "install/dirs: not an absolute plain path once resolved: $line"
    base_dirs+=("$d")
    cache_dirs+=("$d")
  done
}

# install_dirs: make the cache dirs and the services' data dirs, 0700. They are
# not in the manifest: they may hold data, and uninstall leaves them.
install_dirs() {
  local d
  for d in "${cache_dirs[@]}" "${service_dirs[@]}"; do install -d -m 0700 -- "$d"; done
}

# check_service_path: every entry of the units' PATH is an existing directory
# the user cannot write: nono --strict-broker-path refuses to start with a
# PATH an agent could put a program on, so such a unit would never start.
check_service_path() {
  local rest=$service_path: d
  while [ -n "$rest" ]; do
    d=${rest%%:*}
    rest=${rest#*:}
    [ -n "$d" ] || die "SERVICE_PATH has an empty entry (the unit's working directory): $service_path"
    plain_dir "$d" ||
      die "SERVICE_PATH: not an absolute path of letters, digits and . _ + @ - (no . or .. segment; systemd splits a unit's lines on blanks and expands %): $d"
    [ -d "$d" ] || die "SERVICE_PATH: $d does not exist (SERVICE_PATH is the PATH of the service units)"
    [ ! -w "$d" ] ||
      die "SERVICE_PATH: $d is writable by you; nono --strict-broker-path refuses such a PATH, so the units would never start. List only directories you cannot write (default /usr/local/bin:/usr/bin:/bin)"
    [ ! -O "$d" ] ||
      die "SERVICE_PATH: $d is owned by you, so you can make it writable again; nono --strict-broker-path refuses a PATH an agent could put a program on. List only directories that root owns (default /usr/local/bin:/usr/bin:/bin)"
  done
}

# on_service_path COMMAND: COMMAND is an executable file in an entry of
# SERVICE_PATH (what `command -v` finds with that PATH).
on_service_path() {
  local rest=$service_path: d
  while [ -n "$rest" ]; do
    d=${rest%%:*}
    rest=${rest#*:}
    if [ -f "$d/$1" ] && [ -x "$d/$1" ]; then return 0; fi
  done
  return 1
}

# grant_path VALUE: a profile grant as an absolute path of this install ($HOME and
# the XDG variables expanded), or failure for one the installer cannot know ($TMPDIR).
grant_path() {
  local v=$1
  # shellcheck disable=SC2016 # the patterns are the literal profile spellings
  case $v in
    '$HOME' | '$HOME/'*) v=$HOME${v#'$HOME'} ;;
    '$XDG_CACHE_HOME' | '$XDG_CACHE_HOME/'*) v=$cache_home${v#'$XDG_CACHE_HOME'} ;;
    '$XDG_CONFIG_HOME' | '$XDG_CONFIG_HOME/'*) v=$config_home${v#'$XDG_CONFIG_HOME'} ;;
    '$XDG_DATA_HOME' | '$XDG_DATA_HOME/'*) v=$data_home${v#'$XDG_DATA_HOME'} ;;
    '$'*) return 1 ;;
  esac
  [[ $v == /* ]] || return 1
  printf '%s' "${v%/}"
}

# at_or_under DIR GRANT: DIR is GRANT or inside it.
at_or_under() {
  case $1/ in "$2"/*) return 0 ;; esac
  return 1
}

# check_path_overlap SERVICE WORKDIR PROFILE: no SERVICE_PATH entry lies in the
# working tree or in a read-write grant of the profile (as the entry is spelled
# and as it resolves). nono --strict-broker-path refuses such a PATH: the agent
# could put a program there, whoever owns the directory. The profile is the one
# installed: the last registered layer's, else the shipped one. Grants the
# installer cannot expand (like $TMPDIR) and those of the profiles and packs it
# extends are not known here.
check_path_overlap() {
  local s=$1 w=$2 p=$3 rest=$service_path: d dr g gr what i f
  local -a grants=("$w") whats=("the working tree $w of the service $s")
  f=$(profile_file "$p")
  while IFS= read -r g; do
    if g=$(grant_path "$g"); then
      grants+=("$g")
      whats+=("the read-write grant $g of the profile $p ($f)")
    fi
  done < <(jq -r '.filesystem.allow // [] | .[]' "$f")
  while [ -n "$rest" ]; do
    d=${rest%%:*}
    rest=${rest#*:}
    dr=$(readlink -f -- "$d")
    for i in "${!grants[@]}"; do
      g=${grants[$i]}
      what=${whats[$i]}
      gr=$(readlink -f -- "$g" 2>/dev/null || printf '%s' "$g")
      if at_or_under "$d" "$g" || at_or_under "$dr" "$gr"; then
        die "SERVICE_PATH: $d is inside $what; the agent can write there, and nono --strict-broker-path refuses such a PATH, so the unit would never start. Use directories outside every grant that root owns"
      fi
    done
  done
}

# unit_text SRC DEST: the text of SRC (a unit or a Caddyfile) with this
# install's values, kept for DEST. A package placeholder goes as a whole token:
# `@NONO@/bin/nono` becomes the path of nono itself, wherever it is. A
# placeholder left (with ISOLATION=0 there is no wrapper to name) refuses the run.
unit_text() {
  local text=
  IFS= read -r -d '' text <"$1" || true
  [ "$ISOLATION" = 0 ] || text=${text//"@AI_SANDBOX_RUN@/bin/ai-sandbox-run"/$PREFIX/bin/ai-sandbox-run}
  text=${text//"@NONO@/bin/nono"/${tool[nono]}}
  text=${text//"@CADDY@/bin/caddy"/${tool[caddy]}}
  text=${text//"@SERVICE_PATH@"/$service_path}
  text=${text//"@XDG_CONFIG_HOME@"/$config_home}
  text=${text//"@XDG_CACHE_HOME@"/$cache_home}
  text=${text//"@HOME@"/$HOME}
  if [[ $text =~ @[A-Z_]+@ ]]; then die "${1#"$root"/}: no value for the placeholder ${BASH_REMATCH[0]}"; fi
  [ -z "${service_files[$2]+x}" ] || die "two services install $2"
  service_files[$2]=$text
}

# service_field SERVICE FIELD: the FIELD of SERVICE in install/services.json,
# one value per line
service_field() {
  jq -r --arg s "$1" --arg f "$2" '.[$s][$f] | if type == "array" then .[] else . end' "$root/install/services.json"
}

# load_service SERVICE SRC: check SERVICE's entry and files (SRC: services or
# services-nono) and build its unit texts, before anything is written.
load_service() {
  local s=$1 src=$2 json=$root/install/services.json p w c u d
  jq -e --arg s "$s" '.[$s] | (.profile | type == "string") and (.workdir | type == "string")
    and (.caddyfile | type == "boolean")
    and (.units, .commands | type == "array" and length > 0 and all(type == "string"))
    and (.dataDirs | type == "array" and all(type == "string"))' "$json" >/dev/null ||
    die "install/services.json: the service $s is not {profile, workdir, caddyfile, units, commands, dataDirs} (nix run .#render writes it)"
  p=$(service_field "$s" profile)
  [[ $p =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "install/services.json: service $s: not a profile name: $p"
  [ -f "$root/profiles/$p.json" ] || die "profiles/$p.json is missing (install/services.json names it)"
  service_profiles+=("$p")
  w=$(resolve "$(service_field "$s" workdir)")
  plain_dir "$w" || die "install/services.json: service $s: the working tree is not an absolute plain path once resolved: $w"
  [ -d "$w" ] || die "service $s works in $w, which does not exist: its units would never start; create it and install again"
  check_path_overlap "$s" "$w" "$p"
  while IFS= read -r c; do
    [[ $c =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || die "install/services.json: service $s: not a command name: $c"
    on_service_path "$c" ||
      die "service $s runs $c, which is not on SERVICE_PATH ($service_path): install it into one of those directories, or add one that holds it and that you cannot write"
  done < <(service_field "$s" commands)
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    plain_dir "$(resolve "$d")" || die "install/services.json: service $s: not an absolute plain data dir once resolved: $d"
    service_dirs+=("$(resolve "$d")")
  done < <(service_field "$s" dataDirs)
  while IFS= read -r u; do
    [[ $u =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]] || die "install/services.json: service $s: not a unit name: $u"
    [ -f "$src/$s/$u.service" ] || die "${src#"$root"/}/$s/$u.service is missing (install/services.json names it)"
    unit_text "$src/$s/$u.service" "$unit_dir/$u.service"
    service_units+=("$u.service")
  done < <(service_field "$s" units)
  if [ "$(service_field "$s" caddyfile)" = true ]; then
    [ -f "$src/$s/Caddyfile" ] || die "${src#"$root"/}/$s/Caddyfile is missing (install/services.json names it)"
    unit_text "$src/$s/Caddyfile" "$web_dir/$s/Caddyfile"
    listen_texts "$s" "${src#"$root"/}"
  fi
}

# proxy_description SERVICE ADDRESS: the Description the module gives the proxy unit
# of SERVICE on ADDRESS.
proxy_description() {
  case $2 in
    ::1 | 127.*) printf 'Compressing loopback proxy for %s' "$1" ;;
    0.0.0.0) printf 'Compressing proxy for %s on every interface' "$1" ;;
    *) printf 'Compressing proxy for %s on %s' "$1" "$2" ;;
  esac
}

# listen_texts SERVICE DIR: the proxy's Caddyfile and unit of SERVICE for PROXY_LISTEN.
# DIR's files are the module's for its default, 127.0.0.1: a `bind 127.0.0.1` line and
# the loopback Description. 0.0.0.0 drops the bind line (Caddy's default, every
# interface); another address replaces it. Either line missing refuses the run.
listen_texts() {
  local s=$1 cf=$web_dir/$1/Caddyfile pu=$unit_dir/$1-proxy.service from to
  from=$'\n\tbind 127.0.0.1\n'
  [[ ${service_files[$cf]} == *"$from"* ]] || die "$2/$s/Caddyfile: no 'bind 127.0.0.1' line for PROXY_LISTEN (nix run .#render writes it)"
  if [ "$proxy_listen" = 0.0.0.0 ]; then to=$'\n'; else to=$'\n\tbind '$proxy_listen$'\n'; fi
  service_files[$cf]=${service_files[$cf]/"$from"/$to}
  from=$'\nDescription='$(proxy_description "$s" 127.0.0.1)$'\n'
  [[ ${service_files[$pu]-} == *"$from"* ]] || die "$2/$s/$s-proxy.service: no unit with the line ${from:1:-1} for PROXY_LISTEN (nix run .#render writes it)"
  to=$'\nDescription='$(proxy_description "$s" "$proxy_listen")$'\n'
  service_files[$pu]=${service_files[$pu]/"$from"/$to}
}

# parse_services: the names of SERVICES (comma- or blank-separated) into services;
# an unknown one is a usage error, found before any tool is looked up (without jq
# the missing-tool message comes first).
parse_services() {
  local json=$root/install/services.json s list=()
  local -A seen=()
  command -v jq >/dev/null 2>&1 || return 0
  IFS=$', \t\n' read -r -d '' -a list <<<"$SERVICES" || true
  for s in "${list[@]}"; do
    if [ -z "$s" ] || [ -n "${seen[$s]+x}" ]; then continue; fi
    seen[$s]=1
    if ! [[ $s =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || ! jq -e --arg s "$s" 'has($s)' "$json" >/dev/null; then
      usage_error "SERVICES: unknown service '$s' (known: $(jq -r 'keys | join(",")' "$json"))"
    fi
    services+=("$s")
  done
}

# load_services: the services parse_services found, from
# services/ (services-nono/ with ISOLATION=0: units without the wrapper),
# checked and built before anything is written. Every value that goes into a
# unit is a plain path: systemd splits on blanks and expands %.
load_services() {
  local src=$root/services s t
  [ "$ISOLATION" = 1 ] || src=$root/services-nono
  [ ${#services[@]} -gt 0 ] || return 0
  plain_dir "$HOME" ||
    die "HOME must be an absolute path of letters, digits and . _ + @ - (no . or .. segment) for the service units: systemd splits on blanks and expands %: $HOME"
  for t in nono caddy; do
    plain_dir "${tool[$t]}" || die "the path of $t, ${tool[$t]}, cannot go into a unit (letters, digits and . _ + @ - only)"
  done
  check_service_path
  for s in "${services[@]}"; do load_service "$s" "$src"; done
}

# install_services: the units and Caddyfiles load_services built.
install_services() {
  local dest i=0
  [ ${#services[@]} -gt 0 ] || return 0
  ensure_scratch
  for dest in "${!service_files[@]}"; do
    i=$((i + 1))
    printf '%s' "${service_files[$dest]}" >"$tmpdir/service-$i"
    put "$tmpdir/service-$i" "$dest" 0644
  done
}

# names_file TEXT FILE: the unit TEXT uses FILE: names it (a Caddyfile, the
# wrapper), runs nono with its profile, or runs the wrapper (its libexec files).
names_file() {
  local t=$1 f=$2 p
  case $f in
    "$profile_dir"/*.json)
      p=${f##*/} p=${p%.json}
      [[ $t == *" --profile $p "* || $t == *" --profile $p"$'\n'* ]]
      ;;
    "$PREFIX"/libexec/ai-sandbox/*) [[ $t == *"$PREFIX/bin/ai-sandbox-run "* ]] ;;
    *) [[ $t == *"$f "* || $t == *"$f"$'\n'* ]] ;;
  esac
}

# restart_units: the units of the last install that a running service would
# keep in their old state: those whose file changed, and those that use a
# Caddyfile, profile or wrapper file this run changed or added.
restart_units() {
  local u f t deps=()
  for f in "${!written[@]}"; do
    case $f in
      "$web_dir"/*/Caddyfile | "$profile_dir"/*.json | "$PREFIX"/bin/ai-sandbox-run | "$PREFIX"/libexec/ai-sandbox/*)
        [ "${old_manifest[$f]-}" = "${written[$f]}" ] || deps+=("$f")
        ;;
    esac
  done
  for u in "${service_units[@]}"; do
    [ -n "${old_manifest[$unit_dir/$u]+x}" ] || continue
    if [ "${old_manifest[$unit_dir/$u]}" != "${written[$unit_dir/$u]}" ]; then
      printf '%s\n' "$u"
      continue
    fi
    t=${service_files[$unit_dir/$u]}
    for f in "${deps[@]}"; do
      if names_file "$t" "$f"; then
        printf '%s\n' "$u"
        break
      fi
    done
  done
}

# The systemctl --user lines that start the services; printed, not run.
service_lines() {
  local IFS=' ' u d port addr re changed=()
  [ ${#services[@]} -gt 0 ] || return 0
  say "to start the services (this script starts none):"
  printf '  systemctl --user daemon-reload\n'
  printf '  systemctl --user enable --now %s\n' "${service_units[*]}"
  # a running unit keeps its old text and files until it is restarted; enable --now does not
  mapfile -t changed < <(restart_units)
  for u in "${!service_files[@]}"; do
    if [[ $u == */Caddyfile ]] && [[ ${service_files[$u]} =~ (^|$'\n'):([0-9]+)[[:space:]] ]]; then
      port=${BASH_REMATCH[2]} d=${u%/Caddyfile} d=${d##*/} addr=0.0.0.0
      re=$'\n''[[:space:]]*bind[[:space:]]+([^[:space:]]+)'
      if [[ ${service_files[$u]} =~ $re ]]; then addr=${BASH_REMATCH[1]}; fi
      case $addr in
        0.0.0.0) say "the proxy of $d listens on every interface: port $port (PROXY_LISTEN; README \"Ports\"); keep it closed in your firewall unless you mean to expose the agent" ;;
        ::1 | 127.*) say "the proxy of $d listens on $addr port $port (this machine only; PROXY_LISTEN, README \"Ports\")" ;;
        *) say "the proxy of $d listens on $addr port $port; keep the port closed in your firewall unless you mean to expose the agent (PROXY_LISTEN; README \"Ports\")" ;;
      esac
    fi
  done
  if [ ${#changed[@]} -gt 0 ]; then
    say "these units, or the Caddyfile, profile or wrapper they use, were installed before and have changed; a running one keeps the old state until it restarts:"
    printf '  systemctl --user try-restart %s\n' "${changed[*]}"
  fi
}

# check_sysctl: sysctl/60-ai-sandbox.conf holds comments and the pinned
# setting only; its setting lines go to sysctl_lines. Root is told to write
# those lines, not to copy a file that a user, or an agent working in a
# writable checkout, could have edited.
check_sysctl() {
  local file=$root/sysctl/60-ai-sandbox.conf line re='^dev\.tty\.legacy_tiocsti = 0$'
  sysctl_lines=()
  [ -f "$file" ] || die "sysctl/60-ai-sandbox.conf is missing"
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | '#'*) continue ;; esac
    [[ $line =~ $re ]] || die "sysctl/60-ai-sandbox.conf: a line other than comments and dev.tty.legacy_tiocsti = 0 (it would be installed by root; 1 would turn the protection off): $line"
    sysctl_lines+=("$line")
  done <"$file"
  [ ${#sysctl_lines[@]} -gt 0 ] || die "sysctl/60-ai-sandbox.conf holds no setting"
}

# print_sysctl: the kernel setting the NixOS module makes (TIOCSTI injection
# off) needs root; the lines are printed, never run.
print_sysctl() {
  local args=() l line
  for l in "${sysctl_lines[@]}"; do args+=("'$l'"); done
  say "the kernel setting that keeps TIOCSTI injection off needs root (this script never runs sudo):"
  line="  printf '%s\\n' ${args[*]} | sudo tee /etc/sysctl.d/60-ai-sandbox.conf >/dev/null"
  printf '%s\n' "$line"
  printf '  sudo sysctl --system\n'
}

# The lines after an install: how to load the aliases, and the PATH the wrapper
# needs.
final_lines() {
  say "to load the aliases, add this line to ~/.bashrc or ~/.zshrc (this script edits neither):"
  printf '  . %s/aliases.sh\n' "$shell_dir"
  if [ "$ISOLATION" = 1 ]; then
    case ":$PATH:" in
      *":$PREFIX/bin:"*) ;;
      *) say "$PREFIX/bin is not on PATH, and the aliases run ai-sandbox-run from it: add it there too, e.g. export PATH=\"$PREFIX/bin:\$PATH\"" ;;
    esac
  fi
  service_lines
  print_sysctl
}

# On exit, success or failure: remove the scratch directory; after a failure
# keep what was written in the manifest, so uninstall finds it.
partial_manifest() {
  local rc=$?
  trap - EXIT
  [ -z "$tmpdir" ] || rm -rf -- "$tmpdir"
  if [ $rc -ne 0 ] && [ ${#written[@]} -gt 0 ]; then write_manifest partial || true; fi
  exit $rc
}

do_install() {
  local p stale
  load_options
  apply_options
  reused_options
  check_options
  check_sysctl
  load_pins
  load_manifest
  load_pack_record
  parse_services
  resolve_deps
  load_bases
  check_harnesses
  load_layers
  load_dirs
  load_services
  preflight
  trap partial_manifest EXIT
  staging=1
  install_wrapper
  install_profiles
  install_layers
  install_bases
  add_base_dirs
  install_options
  copy_profiles
  install_shell
  install_services
  check_make_dirs
  stale=()
  for p in "${!old_manifest[@]}"; do [ -n "${queued[$p]+x}" ] || stale+=("$p"); done
  check_removable install "${stale[@]}"
  install_packs
  flush_puts
  install_dirs
  remove_stale
  write_manifest
  say "installed ${#written[@]} file(s); manifest $manifest"
  final_lines
}

do_uninstall() {
  local p n=0 rc=0
  if [ ! -f "$manifest" ] && [ ! -f "$packs_file" ]; then
    say "nothing to uninstall: no manifest at $manifest"
    return 0
  fi
  load_manifest
  load_pack_record
  check_removable uninstall "${!old_manifest[@]}"
  for p in "${!old_manifest[@]}"; do
    remove_managed "$p" "${old_manifest[$p]}"
    n=$((n + 1))
  done
  rm -f -- "$manifest"
  remove_packs || rc=1
  say "removed $n file(s); directories created by the install stay"
  return $rc
}

main() {
  local cmd=install
  while [ $# -gt 0 ]; do
    case $1 in
      install | uninstall) cmd=$1 ;;
      --layer)
        [ $# -ge 2 ] || usage
        new_layers+=("$2")
        shift
        ;;
      *) usage ;;
    esac
    shift
  done
  [ "$cmd" = install ] || [ ${#new_layers[@]} -eq 0 ] || usage
  check_dirs
  case $cmd in
    install) do_install ;;
    uninstall) do_uninstall ;;
  esac
}

# Sourced (by the checks), the functions are defined and nothing runs.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
