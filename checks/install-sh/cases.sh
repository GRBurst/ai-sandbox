# Cases for scripts/install.sh without Nix (run by default.nix; sourced into a
# build). The installer runs under `env -i` with a PATH of stubs, bash,
# coreutils and the tools of scripts/deps only, so a tool it uses without
# declaring it, or a call to `nix` or `sudo`, fails here.
# Inputs: REPO (a writable copy of the source, shebangs of its executables
# patched), BASH_BIN, BASE, JQ_BIN, GIT_BIN, SOCAT_BIN, UL_BIN, ZSH_BIN
# (bin directories), OPENCODE_BIN (a read-only bin directory with an opencode
# stub), ALIASES_JSON (the module's aliases, see default.nix), LISTEN_TREE and LISTEN_ADDRS
# (the module's service files for other proxy listen addresses).
set -euo pipefail
: "${REPO:?}" "${BASH_BIN:?}" "${BASE:?}" "${JQ_BIN:?}" "${GIT_BIN:?}" "${SOCAT_BIN:?}" "${UL_BIN:?}"
: "${ZSH_BIN:?}" "${OPENCODE_BIN:?}" "${ALIASES_JSON:?}" "${LISTEN_TREE:?}" "${LISTEN_ADDRS:?}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d)
calls=$work/calls
: >"$calls"
nono_calls=$work/nono-calls
: >"$nono_calls"

# ---- stubs ---------------------------------------------------------------
mkstub() { # mkstub DIR NAME BODY
  mkdir -p "$1"
  printf '#!%s/bash\n%s\n' "$BASH_BIN" "$3" >"$1/$2"
  chmod +x "$1/$2"
}
stubs=$work/stubs
# nono: `list --installed --json` prints its pack store, `pull <pack>@<version>` and
# `remove <pack>` change it and are recorded in $nono_calls; anything else prints the
# version. The store is $HOME.nono-packs (`<pack> <version>` lines), beside the home and
# not in it, so a home an uninstall emptied stays empty. NONO_STUB_LIST_RC fails the
# listing, NONO_STUB_LIST_ARRAY prints a listing whose packages are an array, and
# NONO_STUB_REMOVE_FAIL refuses every remove; NONO_STUB_PULL_FAIL fails the pull of
# that pack, `*` of every pack (offline).
mkstub "$stubs" nono "$(
  cat <<EOF
store=\$HOME.nono-packs
declare -A have=()
if [ -f "\$store" ]; then while read -r p v; do have[\$p]=\$v; done <"\$store"; fi
save() { local p; for p in "\${!have[@]}"; do printf '%s %s\n' "\$p" "\${have[\$p]}"; done >"\$store"; }
case \${1-} in
  list)
    [ "\${NONO_STUB_LIST_RC:-0}" = 0 ] || { echo "nono: cannot read the lockfile" >&2; exit "\$NONO_STUB_LIST_RC"; }
    [ -z "\${NONO_STUB_LIST_ARRAY-}" ] || { echo '{"lockfile_version":4,"packages":[]}'; exit 0; }
    sep=
    printf '{"lockfile_version":4,"packages":{'
    for p in "\${!have[@]}"; do printf '%s"%s":{"version":"%s"}' "\$sep" "\$p" "\${have[\$p]}"; sep=,; done
    printf '}}\n'
    ;;
  pull)
    echo "nono \$*" >>$nono_calls
    case \${NONO_STUB_PULL_FAIL-} in '*' | "\${2%@*}") echo "nono: registry unreachable" >&2; exit 1 ;; esac
    have[\${2%@*}]=\${2#*@}
    save
    ;;
  remove)
    echo "nono \$*" >>$nono_calls
    [ -z "\${NONO_STUB_REMOVE_FAIL-}" ] || { echo "nono: remove refused" >&2; exit 1; }
    [ -n "\${have[\$2]+x}" ] || { echo "nono: package \$2 is not installed" >&2; exit 1; }
    unset "have[\$2]"
    save
    ;;
  *) echo "nono \${NONO_STUB_VERSION:-99.0.0}" ;;
esac
EOF
)"
mkstub "$stubs" bwrap "exit \${BWRAP_STUB_RC:-0}"
mkstub "$stubs" caddy 'exit 0'
mkstub "$stubs" xdg-open 'exit 0'
# `nix` and `sudo` record every call: the installer must make none
mkstub "$stubs" nix "echo \"nix \$*\" >>$calls"
mkstub "$stubs" sudo "echo \"sudo \$*\" >>$calls"
# the same stubs minus one tool, for the missing-tool cases
without() { # without TOOL...: a stub directory without the named stubs
  local d=$work/stubs-without-$*
  d=${d// /-}
  rm -rf "$d"
  cp -r "$stubs" "$d"
  local t
  for t in "$@"; do rm -f "$d/$t"; done
  echo "$d"
}
path_of() { # path_of STUBDIR [EXTRA_BIN...]
  local d=$1
  shift
  local IFS=:
  echo "$d:$BASE${*:+:$*}"
}
full_path=$(path_of "$stubs" "$JQ_BIN" "$GIT_BIN" "$SOCAT_BIN" "$UL_BIN")

# ---- runner ----------------------------------------------------------------
# new_case NAME: a fresh home and the full PATH; the installer of R (REPO)
new_case() {
  c=$1
  H=$work/$c/home
  mkdir -p "$H"
  P=$full_path
  R=$REPO
  ENVV=()
  out=$work/$c.out
  err=$work/$c.err
  : >"$calls"
  : >"$nono_calls"
}
run_installer() { # run_installer ARGS...: status in $rc
  rc=0
  env -i HOME="$H" PATH="$P" "${ENVV[@]}" "$BASH_BIN/bash" "$R/scripts/install.sh" "$@" >"$out" 2>"$err" || rc=$?
  expect_no_calls
}
own_repo() { # own_repo: R is a copy of REPO for this case only (its data files edited)
  R=$work/$c/repo
  cp -r "$REPO" "$R"
}
run_script() { # run_script FILE: a script that sources the installer; status in $rc
  rc=0
  env -i HOME="$H" PATH="$P" REPO="$REPO" "${ENVV[@]}" "$BASH_BIN/bash" "$1" >"$out" 2>"$err" || rc=$?
  expect_no_calls
}
expect_rc() { [ "$rc" = "$1" ] || fail "$c: exit $rc, want $1 ($(cat "$err"))"; }
expect_err() { grep -qF -- "$1" "$err" || fail "$c: stderr lacks '$1' ($(cat "$err"))"; }
expect_no_err() { ! grep -qF -- "$1" "$err" || fail "$c: stderr has '$1'"; }
expect_no_calls() { [ ! -s "$calls" ] || fail "$c: the installer called nix or sudo: $(cat "$calls")"; }
manifest_of() { echo "$H/.local/share/ai-sandbox/manifest"; }
# wrapper_lines: the number of manifest lines under the default bin and libexec
wrapper_lines() { grep -cF -e "  $H/.local/bin/" -e "  $H/.local/libexec/" "$(manifest_of)" || true; }

# ---- tools -----------------------------------------------------------------
new_case deps-ok
run_installer install
expect_rc 0
[ -f "$(manifest_of)" ] || fail "$c: no manifest"
[ "$(wrapper_lines)" = 4 ] || fail "$c: the manifest does not list the four wrapper files"
[ ! -s "$err" ] || fail "$c: unexpected stderr: $(cat "$err")"

new_case deps-missing-jq
P=$(path_of "$stubs" "$GIT_BIN" "$SOCAT_BIN" "$UL_BIN")
run_installer install
expect_rc 1
expect_err jq
[ ! -e "$(manifest_of)" ] || fail "$c: a manifest was written"
[ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written to the home"

new_case deps-all-missing-listed
P=$(path_of "$(without bwrap)" "$GIT_BIN" "$SOCAT_BIN" "$UL_BIN")
run_installer install
expect_rc 1
expect_err jq
expect_err bwrap

new_case isolation-off
P=$(path_of "$(without bwrap)" "$JQ_BIN")
ENVV=(ISOLATION=0)
run_installer install
expect_rc 0

new_case services-need-caddy
P=$(path_of "$(without caddy)" "$JQ_BIN" "$GIT_BIN" "$SOCAT_BIN" "$UL_BIN")
ENVV=(SERVICES=opencode-web)
run_installer install
expect_rc 1
expect_err caddy
ENVV=()
run_installer install
expect_rc 0 # caddy is not needed without services

new_case optional-xdg-open
P=$(path_of "$(without xdg-open)" "$JQ_BIN" "$GIT_BIN" "$SOCAT_BIN" "$UL_BIN")
run_installer install
expect_rc 0
expect_err xdg-open

new_case usage
run_installer bogus
expect_rc 2

# an exported CDPATH does not change where the installer finds its files
new_case cdpath
rc=0
(cd "$REPO" && env -i HOME="$H" PATH="$P" CDPATH=. "$BASH_BIN/bash" scripts/install.sh install) >"$out" 2>"$err" || rc=$?
expect_rc 0
[ -x "$H/.local/bin/ai-sandbox-run" ] || fail "$c: the wrapper was not installed"

# bash 3.2 must reach the version check: it comes before the first bash-4 feature
guard=$(grep -n -m 1 'BASH_VERSINFO' "$REPO/scripts/install.sh" | cut -d: -f1)
assoc=$(grep -n -m 1 'declare -A' "$REPO/scripts/install.sh" | cut -d: -f1)
[ "$guard" -lt "$assoc" ] || fail "bash-version: the version check (line $guard) comes after declare -A (line $assoc)"

# ---- install and uninstall by the script itself -----------------------------------
# the README runs it directly (scripts/install.sh install), so it must be executable (git mode)
[ -x "$REPO/scripts/install.sh" ] || fail "scripts/install.sh is not executable: the README runs it directly"
new_case script-install
# executed directly through its shebang, as the README tells users to run it
rc=0
env -i HOME="$H" PATH="$P" "${ENVV[@]}" "$R/scripts/install.sh" install >"$out" 2>"$err" || rc=$?
expect_rc 0
expect_no_calls
[ -x "$H/.local/bin/ai-sandbox-run" ] || fail "$c: scripts/install.sh install did not install the wrapper"
[ "$(wrapper_lines)" = 4 ] || fail "$c: the manifest does not list the four wrapper files"
rc=0
env -i HOME="$H" PATH="$P" "${ENVV[@]}" "$R/scripts/install.sh" uninstall >"$out" 2>"$err" || rc=$?
expect_rc 0
expect_no_calls
[ -z "$(find "$H" -type f -print -quit)" ] || fail "$c: files stayed after scripts/install.sh uninstall: $(find "$H" -type f)"

# ---- the wrapper ---------------------------------------------------------------
src=$REPO/packages/ai-sandbox-run
wrapper_vars="all_layers default_layers docker_sockets system_sockets runtime_root shim_bin url_relay bwrap socat jq git nono_bin coreutils"
assign() { sed -n "s/^$2=//p" "$1"; } # the value of a variable assignment line

new_case wrapper-installed
run_installer install
expect_rc 0
bin=$H/.local/bin/ai-sandbox-run
lx=$H/.local/libexec/ai-sandbox
for f in "$bin" "$lx/shim/xdg-open" "$lx/ai-sandbox-url-relay" "$lx/ai-sandbox-url-check"; do
  [ -x "$f" ] || fail "$c: $f is missing or not executable"
  [ "$(head -n 1 "$f")" = '#!/usr/bin/env bash' ] || fail "$c: $f has no shebang"
  ! grep -qE '@[A-Za-z_]+@' "$f" || fail "$c: a placeholder is left in $f"
  "$BASH_BIN/bash" -n "$f" || fail "$c: $f does not parse"
done
[ "$(wrapper_lines)" = 4 ] || fail "$c: the manifest does not list the four files"
(cd / && sha256sum --check --quiet "$(manifest_of)") || fail "$c: manifest hashes do not match"
for v in $wrapper_vars; do grep -q "^$v=" "$bin" || fail "$c: the wrapper does not assign $v"; done
[ "$(assign "$bin" bwrap)" = "$stubs/bwrap" ] || fail "$c: bwrap is not the resolved path"
[ "$(assign "$bin" nono_bin)" = "$stubs/nono" ] || fail "$c: nono_bin is not the resolved path"
[ "$(assign "$bin" jq)" = "$JQ_BIN/jq" ] || fail "$c: jq is not the resolved path"
[ "$(assign "$bin" shim_bin)" = "$lx/shim" ] || fail "$c: shim_bin"
[ "$(assign "$bin" url_relay)" = "$lx/ai-sandbox-url-relay" ] || fail "$c: url_relay"
[ -x "$(assign "$bin" coreutils)/id" ] || fail "$c: coreutils is not a directory with id"
[ "$(assign "$bin" all_layers)" = "(session docker system pid tmp git userns)" ] || fail "$c: all_layers"
[ "$(assign "$bin" default_layers)" = "(session docker system pid tmp git userns)" ] || fail "$c: default_layers"
[ "$(assign "$bin" runtime_root)" = /run/user ] || fail "$c: runtime_root"
# sandbox-run.sh follows the preamble verbatim, and the helpers verbatim too
tail -n "$(wc -l <"$src/sandbox-run.sh")" "$bin" | cmp -s - "$src/sandbox-run.sh" || fail "$c: the wrapper body is not sandbox-run.sh"
tail -n "$(wc -l <"$src/sandbox-url-check.sh")" "$lx/ai-sandbox-url-check" | cmp -s - "$src/sandbox-url-check.sh" || fail "$c: url-check body"
tail -n "$(wc -l <"$src/sandbox-xdg-open.sh")" "$lx/shim/xdg-open" | cmp -s - "$src/sandbox-xdg-open.sh" || fail "$c: shim body"
tail -n "$(wc -l <"$src/sandbox-url-relay.sh")" "$lx/ai-sandbox-url-relay" | cmp -s - "$src/sandbox-url-relay.sh" || fail "$c: relay body"
grep -qx "xdg_open=$stubs/xdg-open" "$lx/ai-sandbox-url-relay" || fail "$c: the relay does not name the resolved xdg-open"
cp "$(manifest_of)" "$work/manifest.wrapper"
cp "$bin" "$work/wrapper.1"
echo "# hand edit" >>"$bin"
run_installer install
expect_rc 0
cmp -s "$work/wrapper.1" "$bin" || fail "$c: a reinstall did not restore the managed wrapper"
cmp -s "$work/manifest.wrapper" "$(manifest_of)" || fail "$c: installing twice changed the manifest"
run_installer uninstall
expect_rc 0
[ -z "$(find "$H" -type f -print -quit)" ] || fail "$c: files stayed after uninstall: $(find "$H" -type f)"

new_case wrapper-isolation-off
ENVV=(ISOLATION=0 BWRAP_STUB_RC=1)
run_installer install
expect_rc 0 # no preflight, no wrapper
[ ! -e "$H/.local/bin/ai-sandbox-run" ] || fail "$c: the wrapper was installed without the isolation"
[ "$(wrapper_lines)" = 0 ] || fail "$c: the manifest lists wrapper files"

new_case wrapper-preflight-fails
ENVV=(BWRAP_STUB_RC=1)
run_installer install
expect_rc 1
expect_err "user namespace"
expect_err "ISOLATION=0"
[ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written"

new_case wrapper-refuses-unmanaged-differing
mkdir -p "$H/.local/bin"
printf 'mine\n' >"$H/.local/bin/ai-sandbox-run"
run_installer install
expect_rc 1
expect_err "$H/.local/bin/ai-sandbox-run"
[ "$(cat "$H/.local/bin/ai-sandbox-run")" = mine ] || fail "$c: the unmanaged wrapper was overwritten"

# the scratch directory is gone after a run, whether it succeeded or not
new_case wrapper-scratch-removed
mkdir -p "$work/$c/tmp"
ENVV=(TMPDIR="$work/$c/tmp")
run_installer install
expect_rc 0
[ -z "$(find "$work/$c/tmp" -mindepth 1 -print -quit)" ] || fail "$c: install left $(find "$work/$c/tmp" -mindepth 1)"
rm -f "$H/.local/libexec/ai-sandbox/ai-sandbox-url-check"
printf 'mine\n' >"$H/.local/libexec/ai-sandbox/ai-sandbox-url-check"
sed -i '/ai-sandbox-url-check$/d' "$(manifest_of)" # now an unmanaged file that differs
run_installer install
expect_rc 1
expect_err "refusing to overwrite"
[ -z "$(find "$work/$c/tmp" -mindepth 1 -print -quit)" ] || fail "$c: a failed install left $(find "$work/$c/tmp" -mindepth 1)"

# coreutils is one directory with every tool the wrapper calls from it (on a
# distribution without merged /usr, the directory of cat may lack some)
new_case wrapper-coreutils-incomplete
mkdir -p "$work/$c/catonly"
ln -s "$(command -v cat)" "$work/$c/catonly/cat"
P=$work/$c/catonly:$full_path
run_installer install
expect_rc 1
expect_err "$work/$c/catonly"
expect_err "realpath"
[ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written"

# uninstall removes a managed file that was edited since, and says so
new_case uninstall-warns-changed
run_installer install
expect_rc 0
echo "# hand edit" >>"$H/.local/bin/ai-sandbox-run"
run_installer uninstall
expect_rc 0
expect_err "$H/.local/bin/ai-sandbox-run changed since the install"
expect_no_err "ai-sandbox-url-check"
[ ! -e "$H/.local/bin/ai-sandbox-run" ] || fail "$c: the edited wrapper stayed"

new_case wrapper-prefix
ENVV=(PREFIX="$H/opt")
run_installer install
expect_rc 0
[ -x "$H/opt/bin/ai-sandbox-run" ] || fail "$c: the wrapper is not under PREFIX"
[ -x "$H/opt/libexec/ai-sandbox/shim/xdg-open" ] || fail "$c: libexec is not under PREFIX"
[ "$(assign "$H/opt/bin/ai-sandbox-run" shim_bin)" = "$H/opt/libexec/ai-sandbox/shim" ] || fail "$c: shim_bin ignores PREFIX"
new_case wrapper-prefix-blank
ENVV=(PREFIX="$H/a b")
run_installer install
expect_rc 1
expect_err "blanks"
[ ! -e "$H/a b" ] || fail "$c: something was written under the blank PREFIX"

# the defaults file of the wrapper can be replaced (the portable suite does)
cat >"$work/defaults-nopid.json" <<'JSON'
{"layers": ["session", "docker", "system", "tmp", "git", "userns"],
 "runtimeRoot": "/tmp/fx/run/user",
 "sockets": {"docker": ["/tmp/fx/docker.sock", "/tmp/fx/absent.sock"],
             "system": ["/tmp/fx/system_bus_socket"]}}
JSON
new_case wrapper-defaults
ENVV=(AI_SANDBOX_DEFAULTS="$work/defaults-nopid.json")
run_installer install
expect_rc 0
bin=$H/.local/bin/ai-sandbox-run
[ "$(assign "$bin" all_layers)" = "(session docker system pid tmp git userns)" ] || fail "$c: all_layers must stay the shipped list"
[ "$(assign "$bin" default_layers)" = "(session docker system tmp git userns)" ] || fail "$c: default_layers from the defaults file"
[ "$(assign "$bin" runtime_root)" = /tmp/fx/run/user ] || fail "$c: runtime_root from the defaults file"
[ "$(assign "$bin" docker_sockets)" = "(/tmp/fx/docker.sock /tmp/fx/absent.sock)" ] || fail "$c: docker_sockets from the defaults file"
[ "$(assign "$bin" system_sockets)" = "(/tmp/fx/system_bus_socket)" ] || fail "$c: system_sockets from the defaults file"

# empty socket lists are valid (the Nix build renders them as `()`)
cat >"$work/defaults-nosockets.json" <<'JSON'
{"layers": ["session"], "runtimeRoot": "/run/user", "sockets": {"docker": [], "system": []}}
JSON
new_case wrapper-defaults-empty-lists
ENVV=(AI_SANDBOX_DEFAULTS="$work/defaults-nosockets.json")
run_installer install
expect_rc 0
bin=$H/.local/bin/ai-sandbox-run
[ "$(assign "$bin" docker_sockets)" = "()" ] || fail "$c: docker_sockets"
[ "$(assign "$bin" system_sockets)" = "()" ] || fail "$c: system_sockets"

# a defaults file of the wrong shape is refused by name, before anything is written
i=0
for bad in '{"layers": ["session"], "sockets": {"docker": [], "system": []}}' \
  '{"layers": ["session"], "runtimeRoot": null, "sockets": {"docker": [], "system": []}}' \
  '{"layers": "session", "runtimeRoot": "/run/user", "sockets": {"docker": [], "system": []}}' \
  '{"layers": ["session"], "runtimeRoot": "/run/user", "sockets": {"docker": [1]}}' \
  'not json' ''; do
  i=$((i + 1))
  new_case "wrapper-defaults-refused-$i"
  if [ -n "$bad" ]; then printf '%s\n' "$bad" >"$work/$c.json"; fi
  ENVV=(AI_SANDBOX_DEFAULTS="$work/$c.json")
  run_installer install
  expect_rc 1
  expect_err "$work/$c.json: not a wrapper defaults file"
  [ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written for the defaults $bad"
done

# ---- prefix and manifest safety -------------------------------------------------
# PREFIX and XDG_DATA_HOME are absolute, of plain characters (socat EXEC splits
# on blanks, commas, colons, quotes), without `.` or `..` segments; the
# installer refuses anything else before it writes or removes a file. A
# literal `~` (zsh passes `PREFIX=~/.local scripts/install.sh install` unexpanded) is relative.
i=0
# shellcheck disable=SC2088 # a literal tilde is the point
for p in rel '~/.local' @H@/x/../y @H@/./y @H@/a,b @H@/a:b "@H@/a'b" '@H@/a"b' '@H@/a b'; do
  for cmd in install uninstall; do
    i=$((i + 1))
    new_case "prefix-refused-$i"
    q=${p//@H@/$H}
    ENVV=(PREFIX="$q")
    run_installer "$cmd"
    expect_rc 1
    expect_err "PREFIX must be"
    [ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: $cmd with PREFIX=$q wrote $(find "$H" -mindepth 1)"
    [ ! -e rel ] && [ ! -e '~' ] || fail "$c: $cmd with PREFIX=$q wrote relative to the working directory"
  done
done
new_case data-home-relative
ENVV=(XDG_DATA_HOME=rel)
run_installer install
expect_rc 1
expect_err "XDG_DATA_HOME must be"
[ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written to the home"
[ ! -e rel ] || fail "$c: a manifest was written relative to the working directory"

# A manifest line that is not `<sha256>  <absolute path under PREFIX or the data
# dir>` refuses install (stale removal) and uninstall before any file is removed.
new_case manifest-refused
run_installer install
expect_rc 0
cp "$(manifest_of)" "$work/$c.good"
h=0000000000000000000000000000000000000000000000000000000000000000
mkdir -p "$H/.local/bin"
mkdir -p "$H/.config/other"
victims=(victim "$H/victim" "$H/.local/bin/victim" "$H/.config/other/victim")
badline=$(($(wc -l <"$work/$c.good") + 1))
for bad in "victim" "$h  victim" "$h  $H/.local/../victim" "$h  $H/.local/./bin/victim" \
  "$h  $H/victim" "${h#0}  $H/.local/bin/victim" "$h $H/.local/bin/victim" "$h  /victim" \
  "$h  $H/.config/other/victim"; do
  for cmd in uninstall install; do
    { cat "$work/$c.good"; printf '%s\n' "$bad"; } >"$(manifest_of)"
    cp "$(manifest_of)" "$work/$c.bad"
    for v in "${victims[@]}"; do printf 'keep\n' >"$v"; done
    run_installer "$cmd"
    expect_rc 1
    expect_err "$(manifest_of):$badline"
    for v in "${victims[@]}"; do
      [ -e "$v" ] || fail "$c: $cmd removed $v for the manifest line '$bad'"
    done
    while read -r _ f; do
      [ -e "$f" ] || fail "$c: $cmd removed $f before refusing the manifest line '$bad'"
    done <"$work/$c.good"
    cmp -s "$work/$c.bad" "$(manifest_of)" || fail "$c: $cmd changed the refused manifest"
  done
done
rm -f "${victims[@]}"

# ---- profiles and layers ---------------------------------------------------------
# The profiles of the selected harnesses (install/harnesses.json: a harness's
# profile and its variants', the GPU ones only with GPU=1) are copied to
# $XDG_CONFIG_HOME/nono/profiles, with the shipped base (install/bases.json) each
# of them extends; then the files of every layer registered with --layer NAME=DIR,
# in registration order, later wins.
want_profiles() { # want_profiles HARNESSES GPU: the names install/harnesses.json selects and their bases
  local names n
  # shellcheck disable=SC2016 # jq variables, not shell ones
  names=$("$JQ_BIN/jq" -r --arg hs "$1" --argjson gpu "$2" '. as $all | $hs | split(",")[] | $all[.]
    | .profile, (.variants[] | select(.gpu == false or $gpu == 1) | .profile)' \
    "$REPO/install/harnesses.json")
  {
    printf '%s\n' "$names"
    for n in $names; do
      # shellcheck disable=SC2016 # jq variables, not shell ones
      "$JQ_BIN/jq" -r --slurpfile b "$REPO/install/bases.json" '.extends[] | select($b[0][.] != null)' "$REPO/profiles/$n.json"
    done
  } | sort -u
}
have_profiles() { # have_profiles DIR: the profile names in DIR, sorted, one line
  find "$1" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//' | sort | tr '\n' ' '
}
pdir() { echo "$H/.config/nono/profiles"; }
layers_of() { echo "$H/.local/share/ai-sandbox/layers"; }

new_case profiles-default
run_installer install
expect_rc 0
[ "$(have_profiles "$(pdir)")" = "$(want_profiles claude,opencode,pi,agy 1 | tr '\n' ' ')" ] ||
  fail "$c: installed $(have_profiles "$(pdir)"), want $(want_profiles claude,opencode,pi,agy 1 | tr '\n' ' ')"
for n in agy-local ai-sandbox-claude claude-local claude-local-gpu opencode-claude opencode-claude-gpu pi-claude; do
  f=$(pdir)/$n.json
  [ -f "$f" ] && [ ! -L "$f" ] || fail "$c: $f is not a regular file"
  cmp -s "$REPO/profiles/$n.json" "$f" || fail "$c: $f is not a copy of profiles/$n.json"
  [ "$(stat -c %a "$f")" = 644 ] || fail "$c: mode of $f"
  grep -qxF "$(sha256sum <"$f" | cut -d' ' -f1)  $f" "$(manifest_of)" || fail "$c: $f is not in the manifest"
done
[ ! -e "$(pdir)/opencode-web.json" ] || fail "$c: a service profile was installed without SERVICES"

new_case profiles-selected
ENVV=("HARNESSES=claude,pi" GPU=0)
run_installer install
expect_rc 0
[ "$(have_profiles "$(pdir)")" = "ai-sandbox-claude claude-local pi-claude " ] || fail "$c: installed $(have_profiles "$(pdir)")"
[ "$(have_profiles "$(pdir)")" = "$(want_profiles claude,pi 0 | tr '\n' ' ')" ] || fail "$c: not the set of install/harnesses.json"

new_case profiles-gpu
ENVV=(HARNESSES=claude GPU=1)
run_installer install
expect_rc 0
[ "$(have_profiles "$(pdir)")" = "ai-sandbox-claude claude-local claude-local-gpu " ] || fail "$c: installed $(have_profiles "$(pdir)")"
# a reinstall that selects less removes the profiles no longer selected
ENVV=(HARNESSES=claude GPU=0)
run_installer install
expect_rc 0
[ "$(have_profiles "$(pdir)")" = "ai-sandbox-claude claude-local " ] || fail "$c: GPU=0 left $(have_profiles "$(pdir)")"

new_case profiles-config-home
ENVV=(XDG_CONFIG_HOME="$H/cfg")
run_installer install
expect_rc 0
[ "$(have_profiles "$H/cfg/nono/profiles")" = "$(want_profiles claude,opencode,pi,agy 1 | tr '\n' ' ')" ] ||
  fail "$c: the profiles are not under XDG_CONFIG_HOME"
[ ! -e "$H/.config" ] || fail "$c: something was written to ~/.config"

# options that are not understood stop the run before anything is written
i=0
for opt in HARNESSES=claude,bogus HARNESSES=claude,,pi "HARNESSES=claude,pi," HARNESSES=,claude GPU=yes GPU=2 ISOLATION=true XDG_CONFIG_HOME=rel \
  "XDG_CONFIG_HOME=@H@/a b" XDG_CONFIG_HOME=@H@/x/../y; do
  i=$((i + 1))
  new_case "options-refused-$i"
  ENVV=("${opt//@H@/$H}")
  run_installer install
  case $opt in
    XDG_CONFIG_HOME=*) expect_rc 1 && expect_err "XDG_CONFIG_HOME must be" ;;
    *) expect_rc 2 && expect_err "${opt%%=*}" ;;
  esac
  [ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: $opt wrote $(find "$H" -mindepth 1)"
  [ ! -e rel ] || fail "$c: $opt wrote relative to the working directory"
done

# a profile this installer did not write and that differs is never overwritten
new_case profiles-refuse-unmanaged
mkdir -p "$(pdir)"
printf '{"mine": true}\n' >"$(pdir)/claude-local.json"
run_installer install
expect_rc 1
expect_err "refusing to overwrite $(pdir)/claude-local.json"
[ "$(cat "$(pdir)/claude-local.json")" = '{"mine": true}' ] || fail "$c: the unmanaged profile was overwritten"
new_case profiles-accept-identical
mkdir -p "$(pdir)"
cp "$REPO/profiles/claude-local.json" "$(pdir)/"
run_installer install
expect_rc 0

# nono may rewrite an installed profile (NONO_AUTO_MIGRATE): a reinstall takes it
# back, uninstall removes the profiles
new_case profiles-reclaimed
run_installer install
expect_rc 0
printf '{"migrated": true}\n' >"$(pdir)/claude-local.json"
run_installer install
expect_rc 0
cmp -s "$REPO/profiles/claude-local.json" "$(pdir)/claude-local.json" || fail "$c: a reinstall did not restore the profile"
run_installer uninstall
expect_rc 0
[ -z "$(find "$H" -type f -print -quit)" ] || fail "$c: files stayed after uninstall: $(find "$H" -type f)"

new_case layer-later-wins
L1=$work/$c/l1 L2=$work/$c/l2 L3=$work/$c/l3
mkdir -p "$L1" "$L2" "$L3"
for f in claude-local both only1; do printf '{"layer": "one"}\n' >"$L1/$f.json"; done
printf '{"layer": "two"}\n' >"$L2/both.json"
printf '{"layer": "three"}\n' >"$L3/both.json"
run_installer install --layer one="$L1" --layer two="$L2"
expect_rc 0
cmp -s "$L1/claude-local.json" "$(pdir)/claude-local.json" || fail "$c: the layer did not win over the shipped profile"
cmp -s "$L2/both.json" "$(pdir)/both.json" || fail "$c: the later layer did not win"
cmp -s "$L1/only1.json" "$(pdir)/only1.json" || fail "$c: a layer's own profile is missing"
cmp -s "$REPO/profiles/pi-claude.json" "$(pdir)/pi-claude.json" || fail "$c: a shipped profile is missing"
[ "$(cat "$(layers_of)")" = "one=$L1"$'\n'"two=$L2" ] || fail "$c: the layers are not recorded in order: $(cat "$(layers_of)")"
grep -qF "  $(layers_of)" "$(manifest_of)" || fail "$c: the layer record is not in the manifest"
# a plain reinstall reapplies the recorded layers
cp "$(manifest_of)" "$work/$c.manifest"
run_installer install
expect_rc 0
cmp -s "$work/$c.manifest" "$(manifest_of)" || fail "$c: a plain reinstall changed the manifest"
cmp -s "$L2/both.json" "$(pdir)/both.json" || fail "$c: a plain reinstall did not reapply the layers"
# a file gone from a layer is removed at the next install
rm "$L1/only1.json"
run_installer install
expect_rc 0
[ ! -e "$(pdir)/only1.json" ] || fail "$c: a profile removed from its layer stayed"
# registering a layer again changes its directory, not its place
run_installer install --layer one="$L3"
expect_rc 0
[ "$(cat "$(layers_of)")" = "one=$L3"$'\n'"two=$L2" ] || fail "$c: re-registering moved the layer: $(cat "$(layers_of)")"
cmp -s "$L2/both.json" "$(pdir)/both.json" || fail "$c: the re-registered layer now wins over a later one"
cmp -s "$REPO/profiles/claude-local.json" "$(pdir)/claude-local.json" || fail "$c: the old directory of the layer still applies"
run_installer uninstall
expect_rc 0
[ -z "$(find "$H" -type f -print -quit)" ] || fail "$c: files stayed after uninstall: $(find "$H" -type f)"

# a layer that is not NAME=DIR with a plain name and an absolute directory of
# JSON profiles is refused before anything is written
lx=$work/layers
mkdir -p "$lx/ok" "$lx/empty" "$lx/broken" "$lx/blank" "$lx/rel"
printf '{}\n' >"$lx/ok/x.json"
printf '{\n' >"$lx/broken/x.json"
printf '{}\n' >"$lx/blank/a b.json"
i=0
for spec in noequals "=$lx/ok" "a b=$lx/ok" "a/b=$lx/ok" x=layers/ok "x=$lx/missing" "x=$lx/empty" \
  "x=$lx/broken" "x=$lx/blank" "x=$lx/ok/x.json"; do
  i=$((i + 1))
  new_case "layer-refused-$i"
  rc=0
  (cd "$work" && env -i HOME="$H" PATH="$P" "$BASH_BIN/bash" "$REPO/scripts/install.sh" install --layer "$spec") >"$out" 2>"$err" || rc=$?
  expect_rc 1
  expect_err "layer"
  [ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: --layer $spec wrote $(find "$H" -mindepth 1)"
done
new_case layer-usage
run_installer install --layer
expect_rc 2
run_installer uninstall --layer x="$lx/ok"
expect_rc 2
[ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written"

# a recorded layer whose directory is gone, or a record that is not
# NAME=DIR lines, refuses the run before anything changes
new_case layer-record-refused
mkdir -p "$work/$c/l1"
printf '{}\n' >"$work/$c/l1/x.json"
run_installer install --layer one="$work/$c/l1"
expect_rc 0
(cd "$H" && find . -type f -exec sha256sum {} + | sort) >"$work/$c.before"
rm -r "$work/$c/l1"
run_installer install
expect_rc 1
expect_err "$work/$c/l1"
(cd "$H" && find . -type f -exec sha256sum {} + | sort) | cmp -s - "$work/$c.before" || fail "$c: a refused run changed files"
mkdir -p "$work/$c/l1"
printf '{}\n' >"$work/$c/l1/x.json"
printf 'not a layer\n' >>"$(layers_of)"
run_installer install
expect_rc 1
expect_err "$(layers_of):2"

# ---- the recorded options --------------------------------------------------------
# HARNESSES, GPU, ISOLATION, SERVICES, SERVICE_PATH and PROXY_LISTEN, when set, are
# recorded ($XDG_DATA_HOME/ai-sandbox/options, in the manifest); an empty one
# reuses its record, `default` drops it. A record that is not NAME=VALUE lines of
# those names refuses the run before anything changes.
options_of() { echo "$H/.local/share/ai-sandbox/options"; }
new_case options-recorded
ENVV=(HARNESSES=claude GPU=0 ISOLATION=0)
run_installer install
expect_rc 0
[ "$(cat "$(options_of)")" = "HARNESSES=claude"$'\n'"GPU=0"$'\n'"ISOLATION=0" ] || fail "$c: the options are not recorded: $(cat "$(options_of)")"
grep -qF "  $(options_of)" "$(manifest_of)" || fail "$c: the options record is not in the manifest"
cp "$(manifest_of)" "$work/$c.manifest"
ENVV=()
run_installer install
expect_rc 0
cmp -s "$work/$c.manifest" "$(manifest_of)" || fail "$c: a plain reinstall did not reuse the options: $(diff "$work/$c.manifest" "$(manifest_of)")"
grep -qF "reusing the options of the last install ($(options_of)): HARNESSES=claude GPU=0 ISOLATION=0" "$out" ||
  fail "$c: the reused options are not named: $(cat "$out")"
# a value given wins and is recorded; `default` drops the record
ENVV=(GPU=default ISOLATION=1)
run_installer install
expect_rc 0
[ "$(cat "$(options_of)")" = "HARNESSES=claude"$'\n'"ISOLATION=1" ] || fail "$c: GPU=default, ISOLATION=1 recorded $(cat "$(options_of)")"
[ "$(have_profiles "$(pdir)")" = "ai-sandbox-claude claude-local claude-local-gpu " ] || fail "$c: GPU=default installed $(have_profiles "$(pdir)")"
[ -f "$H/.local/bin/ai-sandbox-run" ] || fail "$c: ISOLATION=1 installed no wrapper"
ENVV=(HARNESSES=default ISOLATION=default)
run_installer install
expect_rc 0
[ ! -e "$(options_of)" ] || fail "$c: the record stayed with every option at its default: $(cat "$(options_of)")"
! grep -qF "  $(options_of)" "$(manifest_of)" || fail "$c: the dropped record is still in the manifest"
! grep -qF "reusing" "$out" || fail "$c: options reused without a record"
[ "$(have_profiles "$(pdir)")" = "$(want_profiles claude,opencode,pi,agy 1 | tr '\n' ' ')" ] || fail "$c: HARNESSES=default installed $(have_profiles "$(pdir)")"
# uninstall removes the record
ENVV=(GPU=0)
run_installer install
expect_rc 0
run_installer uninstall
expect_rc 0
[ ! -e "$(options_of)" ] || fail "$c: uninstall left the options record"

# a record that is not NAME=VALUE lines of the recorded options refuses the run, nothing changes
i=0
for line in 'BOGUS=1' 'PREFIX=/opt' 'GPU' ' GPU=0' 'GPU='; do
  i=$((i + 1))
  new_case "options-record-refused-$i"
  ENVV=(GPU=0)
  run_installer install
  expect_rc 0
  printf '%s\n' "$line" >>"$(options_of)"
  (cd "$H" && find . -type f -exec sha256sum {} + | sort) >"$work/$c.before"
  ENVV=()
  run_installer install
  expect_rc 1
  expect_err "$(options_of):2: not a NAME=VALUE line"
  (cd "$H" && find . -type f -exec sha256sum {} + | sort) | cmp -s - "$work/$c.before" || fail "$c: a refused run changed files"
done

# a recorded value is checked like a given one
new_case options-record-value
ENVV=(GPU=0)
run_installer install
expect_rc 0
printf 'GPU=2\n' >"$(options_of)"
ENVV=()
run_installer install
expect_rc 2
expect_err "GPU must be 0 or 1: 2"

# an option value is one line (the record has one per line)
for o in HARNESSES SERVICES SERVICE_PATH PROXY_LISTEN; do
  new_case "options-newline-$o"
  ENVV=("$o=claude"$'\n'"pi")
  run_installer install
  expect_rc 2
  expect_err "$o must be a single line"
  [ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written"
done

# an install under one XDG_CONFIG_HOME is removed under the same one
new_case config-home-uninstall-elsewhere
ENVV=(XDG_CONFIG_HOME="$H/c1")
run_installer install
expect_rc 0
ENVV=(XDG_CONFIG_HOME="$H/c2")
run_installer uninstall
expect_rc 1
expect_err "XDG_CONFIG_HOME"
[ -f "$H/c1/nono/profiles/claude-local.json" ] || fail "$c: an uninstall under another XDG_CONFIG_HOME removed files"
ENVV=(XDG_CONFIG_HOME="$H/c1")
run_installer uninstall
expect_rc 0


# ---- shell and dirs --------------------------------------------------------------
# $PREFIX/share/ai-sandbox/shell gets aliases.sh (@SHELL_DIR@ = that directory),
# variant.sh and the alias files of the selected harnesses and variants (from
# aliases.d, or aliases-nono.d with ISOLATION=0); the rc files are never edited.
# Sourced by bash and by zsh, the installed aliases.sh defines exactly the
# aliases the module defines for the same selection.
sdir() { echo "$H/.local/share/ai-sandbox/shell"; }
# the alias table after sourcing FILE (zsh has aliases of its own: cleared first), one `name<TAB>base64(value)` line per alias, sorted
bash_aliases() {
  # shellcheck disable=SC2016 # expanded by the inner shell
  env -i PATH="$BASE" "$BASH_BIN/bash" --norc --noprofile -c 'unalias -a; . "$1" || exit 1
    for k in "${!BASH_ALIASES[@]}"; do printf "%s\t%s\n" "$k" "$(printf %s "${BASH_ALIASES[$k]}" | base64 -w0)"; done
    printf "NONO_AUTO_MIGRATE=%s\n" "$(printenv NONO_AUTO_MIGRATE)"' _ "$1" | sort
}
zsh_aliases() {
  # shellcheck disable=SC2016 # expanded by the inner shell
  env -i PATH="$BASE" "$ZSH_BIN/zsh" -f -c 'unalias -m "*"; . "$1" || exit 1
    for k in ${(k)aliases}; do printf "%s\t%s\n" "$k" "$(printf %s "${aliases[$k]}" | base64 -w0)"; done
    printf "NONO_AUTO_MIGRATE=%s\n" "$(printenv NONO_AUTO_MIGRATE)"' _ "$1" | sort
}
want_aliases() { # want_aliases ISOLATION GPU HARNESSES: the module's aliases of that selection
  # shellcheck disable=SC2016 # jq variables
  "$JQ_BIN/jq" -r --arg iso "$1" --argjson gpu "$2" --arg hs "$3" '
    ($hs | split(",")) as $hs | .harness as $h | .gpu as $g | .session as $s
    | (.values[$iso] | to_entries[] | . as $e
      | select(any($hs[]; . == $h[$e.key]))
      | select($gpu == 1 or (any($g[]; . == $e.key) | not))
      | "\($e.key)\t\($e.value | @base64)"),
      "NONO_AUTO_MIGRATE=\($s.NONO_AUTO_MIGRATE)"' "$ALIASES_JSON" | sort
}
# check_aliases ISOLATION GPU HARNESSES: both shells read back the module's aliases
check_aliases() {
  want_aliases "$@" >"$work/$c.want"
  [ "$(wc -l <"$work/$c.want")" -gt 1 ] || fail "$c: no alias wanted for $*"
  bash_aliases "$(sdir)/aliases.sh" >"$work/$c.bash" || fail "$c: bash cannot source the installed aliases.sh"
  zsh_aliases "$(sdir)/aliases.sh" >"$work/$c.zsh" || fail "$c: zsh cannot source the installed aliases.sh"
  diff "$work/$c.want" "$work/$c.bash" >&2 || fail "$c: the aliases bash reads back differ from the module's (ISOLATION GPU HARNESSES = $*)"
  diff "$work/$c.want" "$work/$c.zsh" >&2 || fail "$c: the aliases zsh reads back differ from the module's (ISOLATION GPU HARNESSES = $*)"
}
home_files() { (cd "$H" && find . -path ./.local -prune -o -path ./.config -prune -o -path ./.cache -prune -o -type f -print | sort); }
# check_alias_files SRC NAME...: the installed aliases.d holds exactly NAME... as copies from SRC
check_alias_files() {
  local src=$1 n have
  shift
  have=$(find "$(sdir)/aliases.d" -type f -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')
  [ "$have" = "$(printf '%s\n' "$@" | sort | tr '\n' ' ')" ] || fail "$c: aliases.d holds $have, want $*"
  for n in "$@"; do
    cmp -s "$REPO/shell/$src/$n" "$(sdir)/aliases.d/$n" || fail "$c: aliases.d/$n is not shell/$src/$n"
  done
}

new_case shell-isolation-on
printf '# my bashrc\n' >"$H/.bashrc"
printf '# my zshrc\n' >"$H/.zshrc"
home_files >"$work/$c.home"
run_installer install
expect_rc 0
# shellcheck disable=SC2046 # the file names have no blanks
check_alias_files aliases.d $(cd "$REPO/shell/aliases.d" && ls)
cmp -s "$REPO/shell/variant.sh" "$(sdir)/variant.sh" || fail "$c: variant.sh is not installed"
sed "s|@SHELL_DIR@|$(sdir)|g" "$REPO/shell/aliases.sh" | cmp -s - "$(sdir)/aliases.sh" || fail "$c: aliases.sh is not the template with @SHELL_DIR@ = $(sdir)"
! grep -qE '@[A-Z_]+@' "$(sdir)/aliases.sh" || fail "$c: a placeholder is left in aliases.sh"
for f in aliases.sh variant.sh aliases.d/claude.sh; do
  [ "$(stat -c %a "$(sdir)/$f")" = 644 ] || fail "$c: mode of $f"
  grep -qF "  $(sdir)/$f" "$(manifest_of)" || fail "$c: $f is not in the manifest"
done
grep -qxF "  . $(sdir)/aliases.sh" "$out" || fail "$c: the line to source aliases.sh is not printed: $(cat "$out")"
grep -qF "$H/.local/bin is not on PATH" "$out" || fail "$c: no PATH hint: $(cat "$out")"
[ "$(cat "$H/.bashrc")" = '# my bashrc' ] && [ "$(cat "$H/.zshrc")" = '# my zshrc' ] || fail "$c: an rc file was edited"
home_files | cmp -s - "$work/$c.home" || fail "$c: files appeared in the home: $(home_files)"
check_aliases 1 1 claude,opencode,pi,agy

new_case shell-isolation-off
P=$(path_of "$(without bwrap)" "$JQ_BIN")
ENVV=(ISOLATION=0)
run_installer install
expect_rc 0
# shellcheck disable=SC2046 # the file names have no blanks
check_alias_files aliases-nono.d $(cd "$REPO/shell/aliases-nono.d" && ls)
grep -qxF "  . $(sdir)/aliases.sh" "$out" || fail "$c: the line to source aliases.sh is not printed"
! grep -qF "not on PATH" "$out" || fail "$c: a PATH hint without the wrapper"
check_aliases 0 1 claude,opencode,pi,agy
# the isolation turned on again (ISOLATION=0 is recorded; default drops it): the other alias set replaces it
P=$full_path
ENVV=(ISOLATION=default)
run_installer install
expect_rc 0
# shellcheck disable=SC2046 # the file names have no blanks
check_alias_files aliases.d $(cd "$REPO/shell/aliases.d" && ls)
check_aliases 1 1 claude,opencode,pi,agy

new_case shell-selected
ENVV=("HARNESSES=claude,pi" GPU=0)
run_installer install
expect_rc 0
check_alias_files aliases.d 00-session.sh claude.sh pi.sh
check_aliases 1 0 claude,pi
bash_aliases "$(sdir)/aliases.sh" | grep -q '^claude_gpu' && fail "$c: a GPU alias with GPU=0"
ENVV=(HARNESSES=claude GPU=1)
run_installer install
expect_rc 0
check_alias_files aliases.d 00-session.sh claude.sh claude-gpu.sh
check_aliases 1 1 claude

new_case shell-on-path
P=$H/.local/bin:$full_path
run_installer install
expect_rc 0
! grep -qF "not on PATH" "$out" || fail "$c: a PATH hint while PREFIX/bin is on PATH"

# install/dirs (the per-command cache dirs, the bases' dirs: the default install has every
# base), resolved against the XDG directories, created 0700; never in the manifest, kept by
# uninstall
want_dirs() { # want_dirs CACHE: install/dirs resolved
  sed -e 's| [^ ]*$||' -e "s|@XDG_CACHE_HOME@|$1|g" -e "s|@XDG_CONFIG_HOME@|$H/.config|g" -e "s|@HOME@|$H|g" "$REPO/install/dirs"
}
check_dirs_made() { # check_dirs_made CACHE
  local d
  [ "$(want_dirs "$1" | wc -l)" -gt 0 ] || fail "$c: install/dirs is empty"
  while IFS= read -r d; do
    [ -d "$d" ] || fail "$c: $d was not created"
    [ "$(stat -c %a "$d")" = 700 ] || fail "$c: $d has mode $(stat -c %a "$d"), want 700"
    [ ! -f "$(manifest_of)" ] || ! grep -qF "  $d" "$(manifest_of)" || fail "$c: $d is in the manifest"
  done < <(want_dirs "$1")
}
new_case dirs-default
run_installer install
expect_rc 0
grep -q '@XDG_CACHE_HOME@' "$REPO/install/dirs" || fail "$c: install/dirs names no cache dir"
check_dirs_made "$H/.cache"
run_installer uninstall
expect_rc 0
check_dirs_made "$H/.cache" # kept: they may hold data

new_case dirs-cache-home
ENVV=(XDG_CACHE_HOME="$work/$c/c")
run_installer install
expect_rc 0
check_dirs_made "$work/$c/c"
[ ! -e "$H/.cache" ] || fail "$c: ~/.cache was used despite XDG_CACHE_HOME"

i=0
for bad in rel "@H@/a b" @H@/x/../y; do
  i=$((i + 1))
  new_case "dirs-cache-home-refused-$i"
  ENVV=(XDG_CACHE_HOME="${bad//@H@/$H}")
  run_installer install
  expect_rc 1
  expect_err "XDG_CACHE_HOME must be"
  [ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written"
  [ ! -e rel ] || fail "$c: a directory was made relative to the working directory"
done

# a dir of install/dirs below HOME (the sandboxed Claude Code's config dir) needs a plain HOME
new_case dirs-home-refused
rmdir "$H"
H=$work/$c/my-home/a%b
mkdir -p "$H"
ENVV=(PREFIX="$work/$c/prefix" XDG_DATA_HOME="$work/$c/data" XDG_CONFIG_HOME="$work/$c/cfg" XDG_CACHE_HOME="$work/$c/cache")
grep -q '^@HOME@/' "$REPO/install/dirs" || fail "$c: install/dirs names no dir below HOME"
run_installer install
expect_rc 1
expect_err "HOME must be an absolute path of letters, digits and . _ + @ - (no . or .. segment) for the directory @HOME@/"
[ -z "$(find "$work/$c" -mindepth 1 ! -path "$work/$c/my-home" ! -path "$H" -print -quit)" ] || fail "$c: something was written: $(find "$work/$c" -mindepth 1)"

# ... but only when a shipped base is installed: HARNESSES=pi installs none, so it
# neither needs a plain HOME for it nor makes the dir
new_case dirs-home-no-base
rmdir "$H"
H=$work/$c/my-home/a%b
mkdir -p "$H"
ENVV=(HARNESSES=pi PREFIX="$work/$c/prefix" XDG_DATA_HOME="$work/$c/data" XDG_CONFIG_HOME="$work/$c/cfg" XDG_CACHE_HOME="$work/$c/cache")
run_installer install
expect_rc 0
[ ! -e "$H/.claude-sandbox" ] || fail "$c: HARNESSES=pi made ~/.claude-sandbox"
[ ! -e "$H/.local/share/opencode" ] || fail "$c: HARNESSES=pi made ~/.local/share/opencode"
[ -d "$work/$c/cache/pi" ] || fail "$c: the cache dirs were not made"

# ... and each base's dir only with that base
new_case dirs-home-per-base
ENVV=(HARNESSES=claude)
run_installer install
expect_rc 0
[ -d "$H/.claude-sandbox" ] || fail "$c: HARNESSES=claude did not make ~/.claude-sandbox"
[ ! -e "$H/.local/share/opencode/claude" ] || fail "$c: HARNESSES=claude made ~/.local/share/opencode/claude"
new_case dirs-home-per-base-opencode
ENVV=(HARNESSES=opencode)
run_installer install
expect_rc 0
[ -d "$H/.local/share/opencode/claude" ] && [ "$(stat -c %a "$H/.local/share/opencode/claude")" = 700 ] ||
  fail "$c: HARNESSES=opencode did not make ~/.local/share/opencode/claude 0700"
[ ! -e "$H/.claude-sandbox" ] || fail "$c: HARNESSES=opencode made ~/.claude-sandbox"

# a dir below @HOME@ names its base, one of install/bases.json; anything else refuses the run
# before anything is written
i=0
for bad in '@HOME@/.x' '@HOME@/.x missing-base' '@HOME@/.x ai-sandbox-claude extra'; do
  i=$((i + 1))
  new_case "dirs-home-base-refused-$i"
  own_repo
  printf '%s\n' "$bad" >>"$R/install/dirs"
  run_installer install
  expect_rc 1
  expect_err "install/dirs:"
  expect_err "must be followed by its base of install/bases.json: $bad"
  [ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: $bad wrote $(find "$H" -mindepth 1)"
done

# a shipped base's dir that is a symlink is refused: nono would grant its target
new_case dirs-base-symlink-refused
mkdir -p "$H/.claude"
ln -s .claude "$H/.claude-sandbox"
run_installer install
expect_rc 1
expect_err "$H/.claude-sandbox is a symbolic link"
[ ! -e "$(manifest_of)" ] || fail "$c: the install went ahead"
ENVV=(HARNESSES=pi)
run_installer install
expect_rc 0
new_case dirs-base-symlink-refused-opencode
mkdir -p "$H/.claude" "$H/.local/share/opencode"
ln -s ../../../.claude "$H/.local/share/opencode/claude"
ENVV=(HARNESSES=opencode)
run_installer install
expect_rc 1
expect_err "$H/.local/share/opencode/claude is a symbolic link"
[ ! -e "$(manifest_of)" ] || fail "$c: the install went ahead"

# ---- services and the sysctl line ----------------------------------------------
# SERVICES: the units of install/services.json, from services/ (services-nono/
# with ISOLATION=0), go to $XDG_CONFIG_HOME/systemd/user and the Caddyfile to
# $XDG_CONFIG_HOME/agent-web/<service>, every placeholder replaced: a package
# placeholder with the path of the tool itself, @SERVICE_PATH@ with
# SERVICE_PATH; the data dirs are made 0700. SERVICE_PATH must hold the
# commands the units run, and none of its entries may be missing or writable
# by the user; else nothing is written. The systemctl --user and sudo lines are
# printed, never run (the stub sudo records a call).
svc_case() { # svc_case NAME: SERVICES=opencode-web, a read-only SERVICE_PATH with opencode, the working tree
  new_case "$1"
  mkdir -p "$H/projects"
  ENVV=(SERVICES=opencode-web SERVICE_PATH="$OPENCODE_BIN")
  svc_caddy=$stubs/caddy
}
want_unit() { # want_unit DIR FILE CFG NONO: the rendered DIR/opencode-web/FILE (DIR relative to REPO, or absolute) with the case's values
  local d=$1
  [[ $d == /* ]] || d=$REPO/$d
  sed -e "s|@AI_SANDBOX_RUN@/bin/ai-sandbox-run|$H/.local/bin/ai-sandbox-run|g" -e "s|@NONO@/bin/nono|$4|g" \
    -e "s|@CADDY@/bin/caddy|$svc_caddy|g" -e "s|@SERVICE_PATH@|$OPENCODE_BIN|g" -e "s|@XDG_CONFIG_HOME@|$3|g" \
    -e "s|@HOME@|$H|g" "$d/opencode-web/$2"
}
check_units() { # check_units DIR CFG NONO: the installed units and Caddyfile are DIR's with the case's values
  local f n
  for n in opencode-web.service opencode-web-proxy.service Caddyfile; do
    if [ "$n" = Caddyfile ]; then f=$2/agent-web/opencode-web/$n; else f=$2/systemd/user/$n; fi
    [ -f "$f" ] || fail "$c: $f was not installed: $(cat "$err")"
    want_unit "$1" "$n" "$2" "$3" | cmp -s - "$f" ||
      fail "$c: $f is not $1/opencode-web/$n with this install's values: $(want_unit "$1" "$n" "$2" "$3" | diff - "$f")"
    ! grep -qE '@[A-Z_]+@' "$f" || fail "$c: a placeholder is left in $f"
    grep -qF "  $f" "$(manifest_of)" || fail "$c: $f is not in the manifest"
  done
  grep -qxF "Environment=PATH=$OPENCODE_BIN" "$2/systemd/user/opencode-web.service" || fail "$c: the unit's PATH is not SERVICE_PATH"
  [ -f "$(pdir)/opencode-web.json" ] || [ "$2" != "$H/.config" ] || fail "$c: the service profile was not installed"
}
# the setting is printed inline, not copied from the checkout: root must not take a file a
# user (or an agent in a writable checkout) can edit
sysctl_line="  printf '%s\\n' 'dev.tty.legacy_tiocsti = 0' | sudo tee /etc/sysctl.d/60-ai-sandbox.conf >/dev/null"
sysctl_reload="  sudo sysctl --system"
nothing_written() { # nothing_written: no manifest, no file in the home but the working tree
  [ ! -e "$(manifest_of)" ] || fail "$c: a manifest was written"
  [ -z "$(find "$H" -mindepth 1 ! -path "$H/projects" -print -quit)" ] || fail "$c: something was written: $(find "$H" -mindepth 1)"
}

svc_case services-default
run_installer install
expect_rc 0
check_units services "$H/.config" "$stubs/nono"
grep -qF "ExecStart=$H/.local/bin/ai-sandbox-run -- $stubs/nono run --profile opencode-web --workdir $H/projects " \
  "$H/.config/systemd/user/opencode-web.service" || fail "$c: the unit does not run nono through the wrapper"
grep -qxF "  systemctl --user daemon-reload" "$out" || fail "$c: no daemon-reload line: $(cat "$out")"
grep -qxF "  systemctl --user enable --now opencode-web.service opencode-web-proxy.service" "$out" ||
  fail "$c: no enable line: $(cat "$out")"
grep -qxF "$sysctl_line" "$out" || fail "$c: the sysctl line is not printed: $(cat "$out")"
grep -qxF "$sysctl_reload" "$out" || fail "$c: the sysctl reload line is not printed: $(cat "$out")"
! grep -qF "$REPO/sysctl" "$out" || fail "$c: root is told to copy a file of the checkout"
cp "$(manifest_of)" "$work/$c.manifest"
run_installer install
expect_rc 0
cmp -s "$work/$c.manifest" "$(manifest_of)" || fail "$c: a reinstall changed the manifest"
run_installer uninstall
expect_rc 0
[ -z "$(find "$H/.config" -type f -print -quit)" ] || fail "$c: uninstall left $(find "$H/.config" -type f)"

new_case services-none
run_installer install
expect_rc 0
grep -qxF "$sysctl_line" "$out" || fail "$c: the sysctl line is not printed: $(cat "$out")"
grep -qxF "$sysctl_reload" "$out" || fail "$c: the sysctl reload line is not printed: $(cat "$out")"
! grep -qF "$REPO/sysctl" "$out" || fail "$c: root is told to copy a file of the checkout"
! grep -qF systemctl "$out" || fail "$c: systemctl lines without SERVICES"
if [ -e "$H/.config/systemd" ] || [ -e "$H/.config/agent-web" ]; then fail "$c: units installed without SERVICES"; fi

svc_case services-config-home
ENVV+=(XDG_CONFIG_HOME="$work/$c/cfg")
run_installer install
expect_rc 0
check_units services "$work/$c/cfg" "$stubs/nono"
[ -f "$work/$c/cfg/nono/profiles/opencode-web.json" ] || fail "$c: the service profile is not under XDG_CONFIG_HOME"

svc_case services-isolation-off
ENVV+=(ISOLATION=0)
run_installer install
expect_rc 0
check_units services-nono "$H/.config" "$stubs/nono"
! grep -qF ai-sandbox-run "$H/.config/systemd/user/opencode-web.service" || fail "$c: the unit runs the wrapper with ISOLATION=0"
! grep -qF AI_SANDBOX_RELAX "$H/.config/systemd/user/opencode-web.service" || fail "$c: the unit sets the relax variable with ISOLATION=0"

# a tool outside a bin/ directory: the unit names the tool itself
svc_case services-nono-elsewhere
mkdir -p "$work/$c/opt/nono-x"
cp "$stubs/nono" "$work/$c/opt/nono-x/nono" # the installer also lists and pulls packs with it
wo=$(without nono)
svc_caddy=$wo/caddy
P=$(path_of "$wo" "$JQ_BIN" "$GIT_BIN" "$SOCAT_BIN" "$UL_BIN" "$work/$c/opt/nono-x")
run_installer install
expect_rc 0
check_units services "$H/.config" "$work/$c/opt/nono-x/nono"

svc_case services-unknown
ENVV=(SERVICES=nope SERVICE_PATH="$OPENCODE_BIN")
run_installer install
expect_rc 2
expect_err "unknown service 'nope'"
nothing_written

svc_case services-two-names
ENVV=(SERVICES="opencode-web, opencode-web" SERVICE_PATH="$OPENCODE_BIN")
run_installer install
expect_rc 0
check_units services "$H/.config" "$stubs/nono"

# every SERVICE_PATH entry exists and is not writable by the user
svc_case services-path-writable
mkdir -p "$work/$c/scratch"
ENVV=(SERVICES=opencode-web SERVICE_PATH="$OPENCODE_BIN:$work/$c/scratch")
run_installer install
expect_rc 1
expect_err "SERVICE_PATH: $work/$c/scratch is writable by you"
nothing_written

svc_case services-path-missing
ENVV=(SERVICES=opencode-web SERVICE_PATH="$OPENCODE_BIN:$work/$c/none")
run_installer install
expect_rc 1
expect_err "SERVICE_PATH: $work/$c/none does not exist"
nothing_written

i=0
for bad in "@O@:" ":@O@" "@O@::@O@" "rel/bin:@O@" "@O@:/a b" "@O@:/a%b" "@O@:/a/../b"; do
  i=$((i + 1))
  svc_case "services-path-refused-$i"
  ENVV=(SERVICES=opencode-web SERVICE_PATH="${bad//@O@/$OPENCODE_BIN}")
  run_installer install
  expect_rc 1
  if [ $i -le 3 ]; then expect_err "SERVICE_PATH has an empty entry"; else expect_err "SERVICE_PATH: not an absolute path"; fi
  nothing_written
done

# the command a unit runs is found on SERVICE_PATH, not on the installer's PATH
svc_case services-command-outside
mkstub "$work/$c/ubin" opencode 'exit 0'
P=$P:$work/$c/ubin
ENVV=(SERVICES=opencode-web SERVICE_PATH="$BASH_BIN")
run_installer install
expect_rc 1
expect_err "runs opencode, which is not on SERVICE_PATH"
nothing_written

# the default SERVICE_PATH (unset or empty)
for v in unset empty; do
  new_case "services-path-default-$v"
  cat >"$work/$c.sh" <<'EOF'
source "$REPO/scripts/install.sh"
printf '%s\n' "$service_path"
EOF
  [ "$v" = unset ] || ENVV=(SERVICE_PATH=)
  run_script "$work/$c.sh"
  expect_rc 0
  [ "$(cat "$out")" = /usr/local/bin:/usr/bin:/bin ] || fail "$c: the default SERVICE_PATH is $(cat "$out")"
done

# a missing working tree: the unit would never start
svc_case services-workdir-missing
rmdir "$H/projects"
run_installer install
expect_rc 1
expect_err "$H/projects"
nothing_written

# HOME goes into the units: blanks and % are refused there
svc_case services-home-refused
H=$work/$c/my-home/a%b
mkdir -p "$H/projects"
ENVV+=(PREFIX="$work/$c/prefix" XDG_DATA_HOME="$work/$c/data" XDG_CONFIG_HOME="$work/$c/cfg" XDG_CACHE_HOME="$work/$c/cache")
# without the dirs of install/dirs below HOME, which refuse such a HOME first (dirs-home-refused)
own_repo
grep -v '^@HOME@/' "$REPO/install/dirs" >"$R/install/dirs"
run_installer install
expect_rc 1
expect_err "HOME must be an absolute path of letters, digits and . _ + @ - (no . or .. segment) for the service units"
if [ -e "$work/$c/data" ] || [ -e "$work/$c/cfg" ] || [ -e "$work/$c/prefix" ]; then fail "$c: something was written"; fi

# the data dirs of install/services.json: resolved, made 0700, not in the manifest
svc_case services-data-dirs
own_repo
# shellcheck disable=SC2016 # $HOME is the module's spelling, resolved by the installer
"$JQ_BIN/jq" '."opencode-web".dataDirs = ["@HOME@/.local/share/oc", "$HOME/oc/data", "@XDG_CACHE_HOME@/oc"]' \
  "$REPO/install/services.json" >"$R/install/services.json"
run_installer install
expect_rc 0
for d in "$H/.local/share/oc" "$H/oc/data" "$H/.cache/oc"; do
  [ -d "$d" ] || fail "$c: the data dir $d was not made"
  [ "$(stat -c %a "$d")" = 700 ] || fail "$c: $d has mode $(stat -c %a "$d"), want 700"
  ! grep -qF "  $d" "$(manifest_of)" || fail "$c: $d is in the manifest"
done

# a directory the install needs that cannot be made (a file in the way, a directory you
# cannot write) or that it cannot make 0700 (not yours) refuses the run before the first write
home_tree() { (cd "$H" && find . -printf '%p %y %m\n' | sort); }
blocked_case() { # blocked_case NAME BLOCKER: run the installer; it names BLOCKER and nothing changed
  home_tree >"$work/$c.tree"
  run_installer install
  expect_rc 1
  expect_err "$2"
  home_tree | cmp -s - "$work/$c.tree" || fail "$c: the refused run changed the home: $(home_tree | diff "$work/$c.tree" -)"
  [ ! -e "$(manifest_of)" ] || fail "$c: a manifest was written"
}
svc_case dirs-blocked-web
mkdir -p "$H/.config"
: >"$H/.config/agent-web"
blocked_case "$c" "$H/.config/agent-web"
new_case dirs-blocked-cache
mkdir -p "$H/.cache"
: >"$H/.cache/pi"
blocked_case "$c" "$H/.cache/pi"
new_case dirs-blocked-cache-parent
: >"$H/.cache"
blocked_case "$c" "$H/.cache"
new_case dirs-blocked-data-home
: >"$H/data"
ENVV=(XDG_DATA_HOME="$H/data")
blocked_case "$c" "$H/data"
new_case dirs-blocked-read-only
mkdir -p "$H/ro"
chmod 555 "$H/ro"
ENVV=(PREFIX="$H/ro/p")
blocked_case "$c" "$H/ro"
chmod 755 "$H/ro"
svc_case dirs-blocked-data-dir
own_repo
"$JQ_BIN/jq" '."opencode-web".dataDirs = ["@HOME@/oc/data"]' "$REPO/install/services.json" >"$R/install/services.json"
mkdir -p "$H/oc"
: >"$H/oc/data"
blocked_case "$c" "$H/oc/data"
new_case dirs-blocked-not-owned
own_repo
printf '%s\n' "$BASH_BIN" >>"$R/install/dirs" # a directory that is not yours: install -d -m 0700 cannot chmod it
blocked_case "$c" "$BASH_BIN"

# install/services.json and the units are checked before anything is written
# (EDIT|MESSAGE: a jq edit of services.json, or unit:LINE appended to the unit)
i=0
for edit in 'del(."opencode-web".workdir)|is not {profile, workdir' \
  '."opencode-web".workdir = "rel"|the working tree is not an absolute plain path' \
  '."opencode-web".dataDirs = ["rel/d"]|not an absolute plain data dir' \
  '."opencode-web".dataDirs = ["@HOME@/a b"]|not an absolute plain data dir' \
  '."opencode-web".commands = ["../opencode"]|not a command name' \
  '."opencode-web".units = ["../x"]|not a unit name' \
  '."opencode-web".units = ["nope"]|services-nono/opencode-web/nope.service is missing' \
  '."opencode-web".profile = "nope"|profiles/nope.json is missing' \
  'unit:@FOO@/bin/x|no value for the placeholder @FOO@' \
  'unit:@NONO@/x|no value for the placeholder @NONO@' \
  'unit:@AI_SANDBOX_RUN@/bin/ai-sandbox-run|no value for the placeholder @AI_SANDBOX_RUN@'; do
  i=$((i + 1))
  svc_case "services-json-refused-$i"
  own_repo
  e=${edit%%|*}
  case $e in
    unit:*) printf 'ExecStartPre=%s\n' "${e#unit:}" >>"$R/services-nono/opencode-web/opencode-web.service" ;;
    *) "$JQ_BIN/jq" "$e" "$REPO/install/services.json" >"$R/install/services.json" ;;
  esac
  ENVV+=(ISOLATION=0)
  run_installer install
  expect_rc 1
  expect_err "${edit#*|}"
  nothing_written
done

# a unit that is not ours is not overwritten
svc_case services-unit-not-ours
mkdir -p "$H/.config/systemd/user"
echo mine >"$H/.config/systemd/user/opencode-web-proxy.service"
run_installer install
expect_rc 1
expect_err "refusing to overwrite $H/.config/systemd/user/opencode-web-proxy.service"
[ "$(cat "$H/.config/systemd/user/opencode-web-proxy.service")" = mine ] || fail "$c: the unit was overwritten"
# the refusal comes before the first write: no half-installed service pair, no wrapper, no manifest
[ -z "$(find "$H" -type f ! -path "$H/.config/systemd/user/opencode-web-proxy.service" -print -quit)" ] ||
  fail "$c: files were written before the refusal: $(find "$H" -type f)"
[ ! -e "$(manifest_of)" ] || fail "$c: a manifest was written"

# the same for a conflict in the profiles, the shell files and the wrapper
for target in .config/nono/profiles/claude-local.json .local/share/ai-sandbox/shell/aliases.sh .local/bin/ai-sandbox-run; do
  svc_case "services-conflict-${target##*/}"
  mkdir -p "$H/${target%/*}"
  echo mine >"$H/$target"
  run_installer install
  expect_rc 1
  expect_err "refusing to overwrite $H/$target"
  [ -z "$(find "$H" -type f ! -path "$H/$target" -print -quit)" ] || fail "$c: files were written before the refusal: $(find "$H" -type f)"
  [ ! -e "$(manifest_of)" ] || fail "$c: a manifest was written"
done

# a unit that is enabled (a *.wants link names it) is not removed by an uninstall or by a reinstall
# without SERVICES: it would run on, with its files gone and the link dangling
enabled_case() { # enabled_case NAME: the service installed and enabled (the links systemctl --user enable makes)
  svc_case "$1"
  run_installer install
  expect_rc 0
  mkdir -p "$H/.config/systemd/user/default.target.wants"
  for u in opencode-web opencode-web-proxy; do ln -s ../$u.service "$H/.config/systemd/user/default.target.wants/$u.service"; done
  cp "$(manifest_of)" "$work/$c.manifest"
}
enabled_case services-enabled-uninstall
run_installer uninstall
expect_rc 1
expect_err "systemctl --user disable --now opencode-web-proxy.service opencode-web.service"
expect_err "default.target.wants/opencode-web.service"
[ -f "$H/.config/systemd/user/opencode-web.service" ] || fail "$c: the enabled unit was removed"
cmp -s "$work/$c.manifest" "$(manifest_of)" || fail "$c: the manifest changed"
[ -f "$H/.local/bin/ai-sandbox-run" ] || fail "$c: files were removed before the refusal"
rm -r "$H/.config/systemd/user/default.target.wants"
run_installer uninstall
expect_rc 0
[ ! -e "$H/.config/systemd/user/opencode-web.service" ] || fail "$c: the disabled unit stayed after uninstall"

# `systemctl --user enable --runtime` links under $XDG_RUNTIME_DIR/systemd/user: enabled too
svc_case services-enabled-runtime
run_installer install
expect_rc 0
mkdir -p "$work/$c/run/systemd/user/default.target.wants"
ln -s "$H/.config/systemd/user/opencode-web.service" "$work/$c/run/systemd/user/default.target.wants/opencode-web.service"
ENVV=(XDG_RUNTIME_DIR="$work/$c/run")
run_installer uninstall
expect_rc 1
expect_err "$work/$c/run/systemd/user/default.target.wants/opencode-web.service"
[ -f "$H/.config/systemd/user/opencode-web.service" ] || fail "$c: the enabled unit was removed"

# a plain reinstall (the upgrade after a git pull) reuses the recorded SERVICES and SERVICE_PATH
enabled_case services-enabled-reinstall-plain
ENVV=()
run_installer install
expect_rc 0
cmp -s "$work/$c.manifest" "$(manifest_of)" || fail "$c: a plain reinstall changed the install: $(diff "$work/$c.manifest" "$(manifest_of)")"
grep -qxF "  systemctl --user enable --now opencode-web.service opencode-web-proxy.service" "$out" || fail "$c: no enable line: $(cat "$out")"

# SERVICES=default drops them: refused while their units are enabled, with the way to keep them
enabled_case services-enabled-reinstall-default
ENVV=(SERVICES=default)
run_installer install
expect_rc 1
expect_err "systemctl --user disable --now opencode-web-proxy.service opencode-web.service"
expect_err "to keep them, run again with SERVICES=opencode-web"
[ -f "$H/.config/systemd/user/opencode-web-proxy.service" ] || fail "$c: the enabled unit was removed"
cmp -s "$work/$c.manifest" "$(manifest_of)" || fail "$c: the manifest changed"
rm -r "$H/.config/systemd/user/default.target.wants"
run_installer install
expect_rc 0
[ ! -e "$H/.config/systemd/user/opencode-web.service" ] || fail "$c: the disabled unit stayed after the reinstall"
! grep -qF SERVICES "$(options_of)" 2>/dev/null || fail "$c: SERVICES=default kept the record"
ENVV=()
run_installer install
expect_rc 0
[ ! -e "$H/.config/systemd/user/opencode-web.service" ] || fail "$c: a plain reinstall brought back the dropped service"

# an install without a record (an older installer): the plain reinstall refuses and names the
# SERVICES that keep the enabled units
enabled_case services-enabled-reinstall-unrecorded
rm "$(options_of)"
grep -vF "  $(options_of)" "$work/$c.manifest" >"$(manifest_of)"
cp "$(manifest_of)" "$work/$c.manifest"
ENVV=()
run_installer install
expect_rc 1
expect_err "to keep them, run again with SERVICES=opencode-web"
cmp -s "$work/$c.manifest" "$(manifest_of)" || fail "$c: the manifest changed"

# PROXY_LISTEN is reused too
svc_case services-listen-recorded
ENVV+=(PROXY_LISTEN=0.0.0.0)
run_installer install
expect_rc 0
ENVV=()
run_installer install
expect_rc 0
! grep -qF bind "$H/.config/agent-web/opencode-web/Caddyfile" || fail "$c: a plain reinstall dropped PROXY_LISTEN=0.0.0.0"
grep -qF "the proxy of opencode-web listens on every interface" "$out" || fail "$c: $(cat "$out")"

# a reinstall that keeps the services and changes a unit prints daemon-reload and try-restart
# for the changed ones; a first install and an identical reinstall print no try-restart
svc_case services-try-restart
run_installer install
expect_rc 0
! grep -qF "systemctl --user try-restart" "$out" || fail "$c: try-restart on a first install: $(cat "$out")"
run_installer install
expect_rc 0
! grep -qF "systemctl --user try-restart" "$out" || fail "$c: try-restart on an identical reinstall"
ENVV=(SERVICES=opencode-web SERVICE_PATH="$OPENCODE_BIN:$BASH_BIN")
run_installer install
expect_rc 0
grep -qxF "  systemctl --user daemon-reload" "$out" || fail "$c: no daemon-reload line"
grep -qxF "  systemctl --user try-restart opencode-web.service" "$out" || fail "$c: no try-restart line for the changed unit: $(cat "$out")"
! grep -qF "try-restart opencode-web.service opencode-web-proxy.service" "$out" || fail "$c: try-restart names an unchanged unit"

# a running unit also keeps its old Caddyfile, profile and wrapper: a change of one restarts
# the units that name it (the proxy its Caddyfile; the server its profile and the wrapper)
svc_case services-try-restart-deps
own_repo
run_installer install
expect_rc 0
printf '# changed\n' >>"$R/services/opencode-web/Caddyfile"
run_installer install
expect_rc 0
grep -qxF "  systemctl --user try-restart opencode-web-proxy.service" "$out" || fail "$c: no try-restart for a changed Caddyfile: $(cat "$out")"
"$JQ_BIN/jq" '.filesystem.read += ["/opt/changed"]' "$REPO/profiles/opencode-web.json" >"$R/profiles/opencode-web.json"
run_installer install
expect_rc 0
grep -qxF "  systemctl --user try-restart opencode-web.service" "$out" || fail "$c: no try-restart for a changed profile: $(cat "$out")"
ENVV+=(AI_SANDBOX_DEFAULTS="$work/defaults-nopid.json")
run_installer install
expect_rc 0
grep -qxF "  systemctl --user try-restart opencode-web.service" "$out" || fail "$c: no try-restart for a changed wrapper: $(cat "$out")"
run_installer install
expect_rc 0
! grep -qF "systemctl --user try-restart" "$out" || fail "$c: try-restart on an identical reinstall: $(cat "$out")"

# a value with an @NAME@ in it would be rewritten by a later substitution, after it was checked
new_case placeholder-prefix
ENVV=(PREFIX="$work/$c/p/@y@")
run_installer install
expect_rc 1
expect_err "looks like a placeholder"
[ -z "$(find "$H" -mindepth 1 -print -quit)" ] && [ ! -e "$work/$c/p" ] || fail "$c: something was written"

svc_case services-path-placeholder
mkstub "$work/$c/ro/@XDG_CACHE_HOME@" opencode 'exit 0'
chmod 555 "$work/$c/ro/@XDG_CACHE_HOME@"
ENVV=(SERVICES=opencode-web SERVICE_PATH="$work/$c/ro/@XDG_CACHE_HOME@")
run_installer install
expect_rc 1
expect_err "@XDG_CACHE_HOME@ looks like a placeholder"
nothing_written

svc_case services-workdir-placeholder
own_repo
"$JQ_BIN/jq" '."opencode-web".workdir = "@HOME@/@Y@"' "$REPO/install/services.json" >"$R/install/services.json"
run_installer install
expect_rc 1
expect_err "the working tree is not an absolute plain path"
nothing_written

# the paths of the tools go into the wrapper's preamble one placeholder at a time
new_case placeholder-tool-path
mkdir -p "$work/$c/@git@"
ln -s "$JQ_BIN/jq" "$work/$c/@git@/jq"
P=$(path_of "$stubs" "$work/$c/@git@" "$GIT_BIN" "$SOCAT_BIN" "$UL_BIN")
run_installer install
expect_rc 1
expect_err "looks like a placeholder"
[ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written"

# nono --strict-broker-path refuses a PATH directory the sandbox can write to: one you own can be
# made writable again, and one inside a read-write grant (the working tree, the profile's allow list)
# is writable for the agent whoever owns it
svc_case services-path-owned
mkstub "$work/$c/own" opencode 'exit 0'
chmod 555 "$work/$c/own"
ENVV=(SERVICES=opencode-web SERVICE_PATH="$work/$c/own")
run_installer install
expect_rc 1
expect_err "SERVICE_PATH: $work/$c/own is owned by you"
nothing_written

svc_case services-path-in-workdir
own_repo
# shellcheck disable=SC2016 # a jq variable
"$JQ_BIN/jq" --arg w "${OPENCODE_BIN%/bin}" '."opencode-web".workdir = $w' "$REPO/install/services.json" >"$R/install/services.json"
run_installer install
expect_rc 1
expect_err "SERVICE_PATH: $OPENCODE_BIN is inside the working tree ${OPENCODE_BIN%/bin} of the service opencode-web"
nothing_written

svc_case services-path-in-grant
own_repo
# shellcheck disable=SC2016 # a jq variable
"$JQ_BIN/jq" --arg g "${OPENCODE_BIN%/bin}" '.filesystem.allow += [$g]' "$REPO/profiles/opencode-web.json" >"$R/profiles/opencode-web.json"
run_installer install
expect_rc 1
expect_err "SERVICE_PATH: $OPENCODE_BIN is inside the read-write grant ${OPENCODE_BIN%/bin} of the profile opencode-web"
nothing_written

# the profile a layer installs over the shipped one is the one compared
svc_case services-path-in-layer-grant
mkdir -p "$work/$c/layer"
# shellcheck disable=SC2016 # a jq variable
"$JQ_BIN/jq" --arg g "${OPENCODE_BIN%/bin}" '.filesystem.allow += [$g]' "$REPO/profiles/opencode-web.json" >"$work/$c/layer/opencode-web.json"
run_installer install --layer mine="$work/$c/layer"
expect_rc 1
expect_err "SERVICE_PATH: $OPENCODE_BIN is inside the read-write grant ${OPENCODE_BIN%/bin} of the profile opencode-web ($work/$c/layer/opencode-web.json)"
nothing_written

# a grant the installer cannot resolve ($TMPDIR) is not compared; the default profile installs
svc_case services-path-grants-ok
run_installer install
expect_rc 0

# the printed sudo line carries the setting itself, and the file it comes from is checked first:
# only the pinned setting (and comments) may be in it, else nothing is written
i=0
for line in 'kernel.core_pattern=|/tmp/x' 'dev.tty.legacy_tiocsti = 2' 'dev.tty.legacy_tiocsti = 0 ; id' '' \
  'dev.tty.legacy_tiocsti = 1'; do
  i=$((i + 1))
  new_case "sysctl-refused-$i"
  own_repo
  printf '%s\n' "$line" >>"$R/sysctl/60-ai-sandbox.conf"
  [ -n "$line" ] || : >"$R/sysctl/60-ai-sandbox.conf"
  run_installer install
  expect_rc 1
  expect_err "sysctl/60-ai-sandbox.conf"
  nothing_written
done

# the enable line starts the proxy: the message names its address and port, loopback by default
svc_case services-port-message
run_installer install
expect_rc 0
grep -qF "the proxy of opencode-web listens on 127.0.0.1 port 15434 (this machine only;" "$out" ||
  fail "$c: the address and port of the proxy are not named: $(cat "$out")"
! grep -qF "every interface" "$out" || fail "$c: the default proxy is said to listen on every interface"
! grep -qF "opens no port" "$out" || fail "$c: the installer says it opens no port, and the proxy will"
grep -qxF $'\tbind 127.0.0.1' "$H/.config/agent-web/opencode-web/Caddyfile" || fail "$c: the Caddyfile does not bind loopback"

# PROXY_LISTEN: the Caddyfile and the proxy unit are the module's for that proxy.listenAddress
# (0.0.0.0, every interface, has no bind line); the message names the address and, off
# loopback, the firewall
for spec in $LISTEN_ADDRS; do
  label=${spec%%=*} addr=${spec#*=}
  for iso in 1 0; do
    svc_case "services-listen-$label-$iso"
    ENVV+=(PROXY_LISTEN="$addr" ISOLATION="$iso")
    run_installer install
    expect_rc 0
    for n in opencode-web-proxy.service Caddyfile; do
      if [ "$n" = Caddyfile ]; then f=$H/.config/agent-web/opencode-web/$n; else f=$H/.config/systemd/user/$n; fi
      want_unit "$LISTEN_TREE/$label" "$n" "$H/.config" "$stubs/nono" | cmp -s - "$f" ||
        fail "$c: $f is not the module's for listenAddress $addr: $(want_unit "$LISTEN_TREE/$label" "$n" "$H/.config" "$stubs/nono" | diff - "$f")"
    done
    case $addr in
      0.0.0.0) want="the proxy of opencode-web listens on every interface: port 15434" ;;
      ::1) want="the proxy of opencode-web listens on ::1 port 15434 (this machine only;" ;;
      *) want="the proxy of opencode-web listens on $addr port 15434; keep the port closed in your firewall" ;;
    esac
    grep -qF "$want" "$out" || fail "$c: no '$want' line: $(cat "$out")"
  done
done

# PROXY_LISTEN must be an IPv4 or IPv6 address (usage error, also without SERVICES)
i=0
for bad in localhost '[::1]' 'fe80::1%eth0' 127.0.0.1:80 256.0.0.1 1.2.3 01.2.3.4 '::1::' ':::' \
  1:2:3:4:5:6:7:8:9 '::g' '127.0.0.1 ' 'a b' '@HOME@'; do
  i=$((i + 1))
  svc_case "services-listen-refused-$i"
  ENVV+=(PROXY_LISTEN="$bad")
  run_installer install
  expect_rc 2
  expect_err "PROXY_LISTEN must be an IPv4 or IPv6 address"
  nothing_written
done
new_case services-listen-refused-without-services
ENVV=(PROXY_LISTEN=localhost)
run_installer install
expect_rc 2
expect_err "PROXY_LISTEN must be an IPv4 or IPv6 address"

# an unknown service is a usage error even where caddy is missing
new_case services-unknown-without-caddy
P=$(path_of "$(without caddy)" "$JQ_BIN" "$GIT_BIN" "$SOCAT_BIN" "$UL_BIN")
ENVV=(SERVICES=nope)
run_installer install
expect_rc 2
expect_err "unknown service 'nope'"

# ---- nono version -------------------------------------------------------------
mkdir -p "$REPO/profiles"
printf '0.80.0\n' >"$REPO/profiles/NONO_VERSION"
for v in 0.79.9 0.8.0; do
  new_case "nono-older-$v"
  ENVV=(NONO_STUB_VERSION="$v")
  run_installer install
  expect_rc 0
  expect_err "older than 0.80.0"
done
for v in 0.80.0 0.81.2 1.0.0; do
  new_case "nono-current-$v"
  ENVV=(NONO_STUB_VERSION="$v")
  run_installer install
  expect_rc 0
  expect_no_err "older than"
done
new_case nono-unreadable
ENVV=(NONO_STUB_VERSION=weird)
run_installer install
expect_rc 0
expect_err "cannot read the nono version"

# ---- nono's registry packs -----------------------------------------------------
# The shipped profiles extend registry packs that nono does not fetch by itself
# (NONO_AUTO_MIGRATE skips a name with a slash), so the installer pulls each one
# an installed profile extends and nono lacks, at the version of scripts/packs,
# and records it; uninstall removes exactly the recorded packs.
packs_of() { echo "$H/.local/share/ai-sandbox/packs"; }
store_of() { echo "$H.nono-packs"; }
pins() { # the `<pack>@<version>` lines of scripts/packs, sorted
  local p v
  while read -r p v; do
    case $p in '' | '#'*) continue ;; esac
    echo "$p@$v"
  done <"$REPO/scripts/packs" | LC_ALL=C sort
}
pin_of() { pins | grep -F "$1@"; } # pin_of PACK
nono_did() { sed -n "s/^nono $1 //p" "$nono_calls"; } # nono_did pull|remove: the arguments, in order
[ "$(pins | wc -l)" = 4 ] || fail "scripts/packs does not pin the four packs: $(pins)"

new_case packs-fresh
run_installer install
expect_rc 0
[ "$(nono_did pull)" = "$(pins)" ] || fail "$c: pulled $(nono_did pull), want every pin: $(pins)"
[ "$(cat "$(packs_of)")" = "$(pins | sed 's/@.*//')" ] || fail "$c: the record is $(cat "$(packs_of)")"
! grep -qF "  $(packs_of)" "$(manifest_of)" || fail "$c: the pack record is in the manifest (a reinstall would drop it)"
grep -qF "pulling the nono pack $(pin_of nolabs-ai/pi)" "$out" || fail "$c: the pull is not announced: $(cat "$out")"

# only the packs of the selected harnesses
new_case packs-subset
ENVV=(HARNESSES=pi)
run_installer install
expect_rc 0
[ "$(nono_did pull)" = "$(pin_of nolabs-ai/pi)" ] || fail "$c: pulled $(nono_did pull)"

# a pack nono has, at any version, is left as it is and is not recorded
new_case packs-present
pins | sed 's/@/ /' >"$(store_of)"
run_installer install
expect_rc 0
[ -z "$(nono_did pull)" ] || fail "$c: pulled $(nono_did pull) though nono had every pack"
[ ! -e "$(packs_of)" ] || fail "$c: a pack record without a pull"
new_case packs-other-version
echo "nolabs-ai/opencode 9.9.9" >"$(store_of)"
run_installer install
expect_rc 0
[ "$(nono_did pull)" = "$(pins | grep -vF nolabs-ai/opencode@)" ] || fail "$c: pulled $(nono_did pull)"
expect_err "nolabs-ai/opencode is at 9.9.9"
! grep -qxF nolabs-ai/opencode "$(packs_of)" || fail "$c: a pack the installer did not pull is recorded"

# a reinstall pulls nothing and keeps the record
new_case packs-reinstall
run_installer install
expect_rc 0
cp "$(packs_of)" "$work/$c.packs"
: >"$nono_calls"
run_installer install
expect_rc 0
[ -z "$(nono_did pull)" ] || fail "$c: a reinstall pulled $(nono_did pull)"
cmp -s "$work/$c.packs" "$(packs_of)" || fail "$c: a reinstall changed the record: $(cat "$(packs_of)")"

# offline: refused before the first file, with the line to run later
new_case packs-offline
ENVV=(NONO_STUB_PULL_FAIL='*')
run_installer install
expect_rc 1
expect_err "nono pull $(pins | head -n 1)"
[ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written: $(find "$H" -mindepth 1)"

# a pull that fails after others: what was pulled is recorded, and uninstall removes it
new_case packs-partial
ENVV=(NONO_STUB_PULL_FAIL=nolabs-ai/opencode)
run_installer install
expect_rc 1
expect_err "nono pull $(pin_of nolabs-ai/opencode)"
[ ! -e "$(manifest_of)" ] || fail "$c: a manifest was written"
[ "$(cat "$(packs_of)")" = "nolabs-ai/antigravity"$'\n'"nolabs-ai/claude" ] || fail "$c: the record is $(cat "$(packs_of)" 2>&1)"
: >"$nono_calls"
ENVV=()
run_installer uninstall
expect_rc 0
[ "$(nono_did remove)" = "nolabs-ai/antigravity"$'\n'"nolabs-ai/claude" ] || fail "$c: removed $(nono_did remove)"
[ -z "$(find "$H" -type f -print -quit)" ] || fail "$c: files stayed after uninstall: $(find "$H" -type f)"

# uninstall removes the packs the installer pulled and no other
new_case packs-uninstall
echo "nolabs-ai/pi 0.0.1" >"$(store_of)"
run_installer install
expect_rc 0
: >"$nono_calls"
run_installer uninstall
expect_rc 0
[ "$(nono_did remove)" = "$(pins | grep -vF nolabs-ai/pi@ | sed 's/@.*//')" ] || fail "$c: removed $(nono_did remove)"
[ "$(cat "$(store_of)")" = "nolabs-ai/pi 0.0.1" ] || fail "$c: the pack store is $(cat "$(store_of)")"
[ -z "$(find "$H" -type f -print -quit)" ] || fail "$c: files stayed after uninstall: $(find "$H" -type f)"

# without nono, uninstall removes the files and keeps the record; a later one removes the packs
new_case packs-uninstall-without-nono
run_installer install
expect_rc 0
P=$(path_of "$(without nono)")
run_installer uninstall
expect_rc 1
expect_err "nono remove nolabs-ai/pi"
[ ! -e "$(manifest_of)" ] || fail "$c: the manifest stayed"
[ "$(cat "$(packs_of)")" = "$(pins | sed 's/@.*//')" ] || fail "$c: the record is $(cat "$(packs_of)" 2>&1)"
P=$full_path
: >"$nono_calls"
run_installer uninstall
expect_rc 0
[ "$(nono_did remove)" = "$(pins | sed 's/@.*//')" ] || fail "$c: removed $(nono_did remove)"
[ -z "$(find "$H" -type f -print -quit)" ] || fail "$c: files stayed after uninstall: $(find "$H" -type f)"

# a recorded pack nono refuses to remove: uninstall removes the files, keeps the record and exits 1
new_case packs-remove-fails
run_installer install
expect_rc 0
ENVV=(NONO_STUB_REMOVE_FAIL=1)
run_installer uninstall
expect_rc 1
expect_err "could not remove the nono pack"
[ "$(cat "$(packs_of)")" = "$(pins | sed 's/@.*//')" ] || fail "$c: the record is $(cat "$(packs_of)" 2>&1)"
[ ! -e "$(manifest_of)" ] || fail "$c: the manifest stayed"

# nono's listing with packages that are not an object: refused before anything is written
new_case packs-list-shape
ENVV=(NONO_STUB_LIST_ARRAY=1)
run_installer install
expect_rc 1
expect_err "cannot read the packs nono has installed"
[ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written: $(find "$H" -mindepth 1)"

# a pack name a nono command would read as a flag is not a pack: scripts/packs refuses it
new_case packs-bad-name
own_repo
printf -- '-evil/pack 1.0.0\n' >>"$R/scripts/packs"
run_installer install
expect_rc 1
expect_err "scripts/packs:"
expect_err "-evil/pack"

# nono cannot list its packs: refused before anything is written
new_case packs-list-fails
ENVV=(NONO_STUB_LIST_RC=3)
run_installer install
expect_rc 1
expect_err "nono list --installed --json"
[ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: something was written: $(find "$H" -mindepth 1)"

# a layer's pack that scripts/packs does not pin is not pulled: a warning names the pull
new_case packs-layer-unpinned
mkdir -p "$work/$c/l"
printf '{"extends": ["example-ns/extra"]}\n' >"$work/$c/l/extra.json"
run_installer install --layer extra="$work/$c/l"
expect_rc 0
expect_err "nono pull example-ns/extra"
[ "$(nono_did pull)" = "$(pins)" ] || fail "$c: pulled $(nono_did pull)"

# ---- shipped bases ---------------------------------------------------------------
# A shipped base (install/bases.json: base -> the registry pack it is made from) is
# installed with the profiles that extend it, and the pack it is made from is pulled
# (no profile extends that pack any more); a reinstall without such a profile removes
# the base, and so does uninstall.
new_case bases-installed
run_installer install
expect_rc 0
f=$(pdir)/ai-sandbox-claude.json
cmp -s "$REPO/profiles/ai-sandbox-claude.json" "$f" || fail "$c: $f is not a copy of profiles/ai-sandbox-claude.json"
grep -qxF "$(sha256sum <"$f" | cut -d' ' -f1)  $f" "$(manifest_of)" || fail "$c: $f is not in the manifest"
nono_did pull | grep -qxF "$(pin_of nolabs-ai/claude)" || fail "$c: the pack of the base was not pulled: $(nono_did pull)"
grep -qF "pulling the nono pack $(pin_of nolabs-ai/claude) (ai-sandbox-claude.json needs it)" "$out" || fail "$c: the pull is not announced: $(cat "$out")"
[ -d "$H/.claude-sandbox" ] && [ "$(stat -c %a "$H/.claude-sandbox")" = 700 ] || fail "$c: ~/.claude-sandbox is not a 0700 directory"
ENVV=(HARNESSES=pi)
run_installer install
expect_rc 0
[ ! -e "$f" ] || fail "$c: HARNESSES=pi left the base"
! grep -qF "  $f" "$(manifest_of)" || fail "$c: the base is still in the manifest"
ENVV=(HARNESSES=claude GPU=0)
run_installer install
expect_rc 0
[ -f "$f" ] || fail "$c: HARNESSES=claude did not install the base again"
run_installer uninstall
expect_rc 0
[ -z "$(find "$H" -type f -print -quit)" ] || fail "$c: files stayed after uninstall: $(find "$H" -type f)"

# the same for the opencode base: with the opencode harness, its pack pulled, its Claude Code
# config dir made 0700; gone with the last profile extending it, and by uninstall
new_case bases-installed-opencode
ENVV=(HARNESSES=opencode GPU=0)
run_installer install
expect_rc 0
f=$(pdir)/ai-sandbox-opencode.json
cmp -s "$REPO/profiles/ai-sandbox-opencode.json" "$f" || fail "$c: $f is not a copy of profiles/ai-sandbox-opencode.json"
grep -qxF "$(sha256sum <"$f" | cut -d' ' -f1)  $f" "$(manifest_of)" || fail "$c: $f is not in the manifest"
[ ! -e "$(pdir)/ai-sandbox-claude.json" ] || fail "$c: HARNESSES=opencode installed the claude base"
nono_did pull | grep -qxF "$(pin_of nolabs-ai/opencode)" || fail "$c: the pack of the base was not pulled: $(nono_did pull)"
grep -qF "pulling the nono pack $(pin_of nolabs-ai/opencode) (ai-sandbox-opencode.json needs it)" "$out" || fail "$c: the pull is not announced: $(cat "$out")"
[ -d "$H/.local/share/opencode/claude" ] && [ "$(stat -c %a "$H/.local/share/opencode/claude")" = 700 ] ||
  fail "$c: ~/.local/share/opencode/claude is not a 0700 directory"
ENVV=(HARNESSES=pi)
run_installer install
expect_rc 0
[ ! -e "$f" ] || fail "$c: HARNESSES=pi left the base"
! grep -qF "  $f" "$(manifest_of)" || fail "$c: the base is still in the manifest"
ENVV=(HARNESSES=opencode GPU=0)
run_installer install
expect_rc 0
run_installer uninstall
expect_rc 0
[ -z "$(find "$H" -type f -print -quit)" ] || fail "$c: files stayed after uninstall: $(find "$H" -type f)"

# a service alone needs its base: SERVICES=opencode-web without the opencode harness installs
# ai-sandbox-opencode, pulls its pack and makes its dir
svc_case bases-service-only
ENVV+=(HARNESSES=claude)
run_installer install
expect_rc 0
f=$(pdir)/ai-sandbox-opencode.json
[ ! -e "$(pdir)/opencode-claude.json" ] || fail "$c: HARNESSES=claude installed the opencode harness's profile"
cmp -s "$REPO/profiles/ai-sandbox-opencode.json" "$f" || fail "$c: the service did not bring its base $f"
grep -qF "  $f" "$(manifest_of)" || fail "$c: $f is not in the manifest"
nono_did pull | grep -qxF "$(pin_of nolabs-ai/opencode)" || fail "$c: the pack of the base was not pulled: $(nono_did pull)"
[ -d "$H/.local/share/opencode/claude" ] || fail "$c: ~/.local/share/opencode/claude was not made"
run_installer uninstall
expect_rc 0
[ ! -e "$f" ] || fail "$c: uninstall left the base"

# a layer's base wins over the shipped one, like any profile, and its pack is still pulled
new_case bases-layer
mkdir -p "$work/$c/l"
printf '{"extends": ["default"], "meta": {"name": "ai-sandbox-claude"}}\n' >"$work/$c/l/ai-sandbox-claude.json"
run_installer install --layer mine="$work/$c/l"
expect_rc 0
cmp -s "$work/$c/l/ai-sandbox-claude.json" "$(pdir)/ai-sandbox-claude.json" || fail "$c: the layer's base did not win"
nono_did pull | grep -qxF "$(pin_of nolabs-ai/claude)" || fail "$c: the pack of the base was not pulled: $(nono_did pull)"

# an install/bases.json that is not a map of base names to packs, or names a base
# profiles/ lacks, refuses the run before anything is written
i=0
for bad in '[]' '{"a b": "nolabs-ai/claude"}' '{"ai-sandbox-claude": "-x/y"}' '{"ai-sandbox-claude": "nolabs-ai/claude@0.1.4"}' \
  '{"ai-sandbox-claude": 1}' '{"missing-base": "nolabs-ai/claude"}' '{'; do
  i=$((i + 1))
  new_case "bases-refused-$i"
  own_repo
  printf '%s\n' "$bad" >"$R/install/bases.json"
  run_installer install
  expect_rc 1
  expect_err "install/bases.json"
  [ -z "$(find "$H" -mindepth 1 -print -quit)" ] || fail "$c: $bad wrote $(find "$H" -mindepth 1)"
  [ -z "$(nono_did pull)" ] || fail "$c: $bad pulled $(nono_did pull)"
done

# ---- put and the manifest ------------------------------------------------------
# a script that sources the installer and calls its functions
cat >"$work/put-new.sh" <<'EOF'
source "$REPO/scripts/install.sh"
mkdir -p "$HOME/src"
printf 'one\n' >"$HOME/src/a"
printf 'two\n' >"$HOME/src/b"
load_manifest
put "$HOME/src/a" "$PREFIX/dst/a" 0644
put "$HOME/src/b" "$PREFIX/dst/sub dir/b" 0755
write_manifest
EOF
new_case put-new
run_script "$work/put-new.sh"
expect_rc 0
[ "$(stat -c %a "$H/.local/dst/a")" = 644 ] || fail "$c: mode of a"
[ "$(stat -c %a "$H/.local/dst/sub dir/b")" = 755 ] || fail "$c: mode of b"
[ "$(wc -l <"$(manifest_of)")" = 2 ] || fail "$c: the manifest does not list exactly the two files"
(cd / && sha256sum --check --quiet "$(manifest_of)") || fail "$c: manifest hashes do not match the files"
grep -qF "  $H/.local/dst/sub dir/b" "$(manifest_of)" || fail "$c: a path with a blank is not listed whole"

cat >"$work/put-refuse.sh" <<'EOF'
source "$REPO/scripts/install.sh"
mkdir -p "$PREFIX/dst" "$HOME/src"
printf 'mine\n' >"$PREFIX/dst/a"
printf 'ours\n' >"$HOME/src/a"
load_manifest
put "$HOME/src/a" "$PREFIX/dst/a" 0644
EOF
new_case put-refuses-unmanaged-differing
run_script "$work/put-refuse.sh"
expect_rc 1
expect_err "$H/.local/dst/a"
[ "$(cat "$H/.local/dst/a")" = mine ] || fail "$c: the unmanaged file was overwritten"

cat >"$work/put-same.sh" <<'EOF'
source "$REPO/scripts/install.sh"
mkdir -p "$PREFIX/dst" "$HOME/src"
printf 'same\n' >"$PREFIX/dst/a"
printf 'same\n' >"$HOME/src/a"
load_manifest
put "$HOME/src/a" "$PREFIX/dst/a" 0600
EOF
new_case put-accepts-unmanaged-identical
run_script "$work/put-same.sh"
expect_rc 0

# put writes under PREFIX or the data dir only: what it writes, a later run
# must be able to remove (the manifest is checked against the same roots)
cat >"$work/put-outside.sh" <<'EOF'
source "$REPO/scripts/install.sh"
mkdir -p "$HOME/src"
printf 'x\n' >"$HOME/src/a"
load_manifest
put "$HOME/src/a" "$HOME/elsewhere/a" 0644
EOF
new_case put-refuses-outside-roots
run_script "$work/put-outside.sh"
expect_rc 1
expect_err "$H/elsewhere/a"
[ ! -e "$H/elsewhere" ] || fail "$c: put wrote outside PREFIX and the data dir"

# a failed run keeps what it wrote in the manifest, so uninstall finds it
cat >"$work/put-partial.sh" <<'EOF'
source "$REPO/scripts/install.sh"
mkdir -p "$PREFIX/dst" "$HOME/src"
printf 'mine\n' >"$PREFIX/dst/b"
printf 'x\n' >"$HOME/src/a"
printf 'y\n' >"$HOME/src/b"
load_manifest
trap partial_manifest EXIT
put "$HOME/src/a" "$PREFIX/dst/a" 0644
put "$HOME/src/b" "$PREFIX/dst/b" 0644
EOF
new_case put-failure-keeps-partial-manifest
run_script "$work/put-partial.sh"
expect_rc 1
grep -qF "  $H/.local/dst/a" "$(manifest_of)" || fail "$c: the file written before the failure is not in the manifest"

# a managed path that is now a directory is not written into
cat >"$work/put-dir.sh" <<'EOF'
source "$REPO/scripts/install.sh"
mkdir -p "$HOME/src"
printf 'x\n' >"$HOME/src/a"
load_manifest
put "$HOME/src/a" "$PREFIX/dst/a" 0644
write_manifest
rm "$PREFIX/dst/a"
mkdir "$PREFIX/dst/a"
written=()
load_manifest
put "$HOME/src/a" "$PREFIX/dst/a" 0644
EOF
new_case put-not-into-directory
run_script "$work/put-dir.sh"
expect_rc 1
[ -z "$(find "$H/.local/dst/a" -mindepth 1 -print -quit)" ] || fail "$c: put wrote into the directory"

# install twice, drop a file, uninstall: back to the start
cat >"$work/round.sh" <<'EOF'
source "$REPO/scripts/install.sh"
mkdir -p "$HOME/src"
printf 'one\n' >"$HOME/src/a"
printf 'two\n' >"$HOME/src/b"
printf 'three\n' >"$HOME/src/c"
load_manifest
put "$HOME/src/a" "$PREFIX/dst/a" 0644
put "$HOME/src/b" "$PREFIX/dst/b" 0644
if [ "${DROP:-}" != c ]; then put "$HOME/src/c" "$PREFIX/dst/c" 0755; fi
remove_stale
write_manifest
EOF
new_case round
mkdir -p "$H/keep"
printf 'user data\n' >"$H/keep/file"
run_script "$work/round.sh" # the sources are written by the script itself
expect_rc 0
before=$(cd "$H" && find . -type f ! -path './.local/*' | sort)
cp "$(manifest_of)" "$work/manifest.1"
run_script "$work/round.sh"
expect_rc 0
cmp -s "$work/manifest.1" "$(manifest_of)" || fail "$c: installing twice changed the manifest"
[ "$(wc -l <"$(manifest_of)")" = 3 ] || fail "$c: the manifest does not list three files"
ENVV=(DROP=c)
echo "# hand edit" >>"$H/.local/dst/c"
run_script "$work/round.sh"
expect_rc 0
expect_err "$H/.local/dst/c changed since the install"
[ ! -e "$H/.local/dst/c" ] || fail "$c: a file that is no longer installed stayed (stale)"
[ "$(wc -l <"$(manifest_of)")" = 2 ] || fail "$c: the stale file is still in the manifest"
ENVV=()
run_script "$work/round.sh"
expect_rc 0
run_installer uninstall
expect_rc 0
[ ! -e "$(manifest_of)" ] || fail "$c: the manifest stayed after uninstall"
for f in a b c; do [ ! -e "$H/.local/dst/$f" ] || fail "$c: dst/$f stayed after uninstall"; done
after=$(cd "$H" && find . -type f ! -path './.local/*' | sort)
[ "$before" = "$after" ] || fail "$c: uninstall changed the other files"
[ "$(cat "$H/keep/file")" = "user data" ] || fail "$c: user data changed"
[ -d "$H/.local/dst" ] || fail "$c: a directory the install created was removed"
run_installer uninstall
expect_rc 0 # nothing left to remove

echo "install-sh: all cases passed"
