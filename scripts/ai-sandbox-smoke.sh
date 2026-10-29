#!/usr/bin/env bash
# Live smoke test for the namespace isolation around nono
# (docs/specs/2026-09-26-sandbox-namespace-isolation-design.md).
# Ad hoc, not part of the flake.
#
# Run it OUTSIDE any sandbox, from a normal terminal, after switching to a
# configuration with the sandbox (for example `nixos-rebuild test --flake
# path:/path/to/your/flake#<host>` or `home-manager switch`). It expects Nix:
# its `nix` and store-owner probes FAIL without it.
# It runs a probe twice through the real wrapper and the real nono profile,
# as the `pi` alias does: once with every layer on, once with
# AI_SANDBOX_RELAX=git,pid. Every expectation prints PASS or FAIL; the exit
# status is 1 if any line is FAIL. Before the switch (no isolation yet) the
# wrapper is missing or the sockets are visible: that is the red run.
#
# The desktop sockets are only tested for existence (test -S); nothing here
# connects to them. It writes a throwaway repo under
# ~/.cache/ai-sandbox-smoke.XXXXXX and a marker file in /tmp, and removes
# both on exit (KEEP=1 keeps the repo and prints its path).
#
# Usage: scripts/ai-sandbox-smoke.sh
# Env:   AI_SANDBOX_RUN  wrapper to test (default: ai-sandbox-run on PATH)
#        PROFILE         nono profile (default: pi-claude, the `pi` alias's)
#        SOCAT           socat for the probe (default: PATH, else the flake's
#                        pinned nixpkgs)
#        KEEP=1          keep the throwaway repo
set -euo pipefail

flake=$(cd "$(dirname "$0")/.." && pwd)
wrapper=${AI_SANDBOX_RUN:-ai-sandbox-run}
profile=${PROFILE:-pi-claude}

die() {
  printf 'ai-sandbox-smoke: %s\n' "$*" >&2
  exit 2
}
command -v "$wrapper" >/dev/null ||
  die "wrapper '$wrapper' not found; switch first (nixos-rebuild test) or set AI_SANDBOX_RUN"
command -v nono >/dev/null || die "nono not found on PATH"
socat=${SOCAT:-$(command -v socat || true)}
if [ -z "$socat" ]; then
  socat=$(nix build --no-link --print-out-paths --no-write-lock-file \
    --inputs-from "path:$flake" nixpkgs#socat)/bin/socat ||
    die "no socat on PATH and building it from the flake's nixpkgs failed; set SOCAT"
fi

work=
marker=
cleanup() {
  if [ -n "$marker" ]; then rm -f -- "$marker"; fi
  if [ -z "$work" ]; then return; fi
  if [ "${KEEP:-0}" = 1 ]; then
    printf 'kept: %s\n' "$work"
  else
    rm -rf -- "$work"
  fi
}
trap cleanup EXIT
work=$(mktemp -d "$HOME/.cache/ai-sandbox-smoke.XXXXXX")
marker=$(mktemp /tmp/ai-sandbox-smoke-marker.XXXXXX)

# Same TMPDIR shape as the alias: ${TMPDIR:-/run/user/$UID}/pi/tmp, private.
TMPDIR=${TMPDIR:-/run/user/$UID}/pi/tmp
export TMPDIR
# As the alias: only the leaf is private (SC2174 is the intended behaviour).
# shellcheck disable=SC2174
mkdir -p -m 700 "$TMPDIR"

proj=$work/proj
mkdir -p "$proj"
git -C "$proj" init -q
git -C "$proj" -c commit.gpgsign=false -c user.email=s@s -c user.name=s \
  commit -q --allow-empty -m init
# An in-tree include target: must be as read-only as .git/config (T1.4b).
printf '[smoke]\n\tx = 0\n' >"$proj/.gitconfig-local"
git -C "$proj" config include.path ../.gitconfig-local

# The probe runs INSIDE the isolation and nono. POSIX sh; one "key=value" per
# line on stdout. Ported from the spike's probe.sh (existence checks only).
cat >"$proj/probe.sh" <<'PROBE'
socat=$1
marker=$2
u=$(id -u)
r() { printf '%s=%s\n' "$1" "$2"; }
export XDG_CACHE_HOME="$TMPDIR/nixcache"

for s in /run/user/$u/bus /run/user/$u/wayland-0 /run/user/$u/wayland-1 \
  /run/user/$u/pulse/native /run/user/$u/pipewire-0 \
  /run/user/$u/systemd/private /run/user/$u/gnupg/S.gpg-agent \
  /run/user/$u/gnupg/S.gpg-agent.ssh /run/user/$u/keyring/control \
  /run/docker.sock /run/podman/podman.sock \
  /run/dbus/system_bus_socket /run/avahi-daemon/socket; do
  if [ -S "$s" ]; then r "hidden:$s" VISIBLE; else r "hidden:$s" hidden; fi
done
if [ -e "$marker" ]; then r hosttmp VISIBLE; else r hosttmp hidden; fi

ok=0
for _ in $(seq 20); do nix store info >/dev/null 2>&1 && ok=$((ok + 1)); done
r nix "$ok/20"
ok=0
for _ in $(seq 20); do getent hosts github.com >/dev/null 2>&1 && ok=$((ok + 1)); done
r nscd "$ok/20"
if getent passwd "$u" >/dev/null 2>&1; then r passwd ok; else r passwd FAIL; fi
sock="$TMPDIR/probe.sock"
rm -f "$sock"
"$socat" UNIX-LISTEN:"$sock",fork EXEC:true >/dev/null 2>&1 &
sp=$!
sleep 0.3
ok=0
for _ in $(seq 10); do "$socat" -u OPEN:/dev/null UNIX-CONNECT:"$sock" 2>/dev/null && ok=$((ok + 1)); done
kill "$sp" 2>/dev/null
rm -f "$sock"
r tmpsock "$ok/10"
if touch "$TMPDIR/w" 2>/dev/null; then r tmpdir ok; else r tmpdir FAIL; fi
if [ -n "${XDG_RUNTIME_DIR:-}" ] && touch "$XDG_RUNTIME_DIR/w" 2>/dev/null; then r nvf ok; else r nvf FAIL; fi
if git status --porcelain >/dev/null 2>&1; then r gitstatus ok; else r gitstatus FAIL; fi
if git -c commit.gpgsign=false -c user.email=s@s -c user.name=s commit -q --allow-empty -m probe 2>/dev/null; then
  r gitcommit ok
else
  r gitcommit FAIL
fi

if git config --local smoke.y 1 2>/dev/null; then r gitconfig allowed; else r gitconfig blocked; fi
if (echo x >.git/hooks/pre-commit) 2>/dev/null; then r hooks allowed; else r hooks blocked; fi
if (echo x >>.gitconfig-local) 2>/dev/null; then r include allowed; else r include blocked; fi
n=0
for _ in /proc/[0-9]*; do n=$((n + 1)); done
r pids "$n"
if unshare -U true 2>/dev/null; then r userns allowed; else r userns blocked; fi
r storeowner "$(stat -c %U /nix/store 2>/dev/null)"
PROBE

fails=0
check() { # mode label got want-description predicate-result
  local status=PASS
  if [ "$5" != 0 ]; then
    status=FAIL
    fails=$((fails + 1))
  fi
  printf '%s  %-8s %-44s %-10s (want %s)\n' "$status" "$1" "$2" "$3" "$4"
}

run_mode() { # mode relax
  local mode=$1 relax=$2 out err key val want ok
  out=$work/out.$mode
  err=$work/err.$mode
  if ! (cd "$proj" && AI_SANDBOX_RELAX=$relax "$wrapper" --nono-alias pi_nono \
    --open-urls-profile "$profile" -- \
    nono run --profile "$profile" --allow-cwd -- sh ./probe.sh "$socat" "$marker") \
    >"$out" 2>"$err"; then
    check "$mode" "probe run" "failed" "exit 0" 1
    sed 's/^/    /' "$err" | tail -15
    return
  fi
  while IFS='=' read -r key val; do
    case $key in
      hidden:* | hosttmp)
        want=hidden
        [ "$val" = hidden ] && ok=0 || ok=1
        ;;
      nix | nscd)
        want=20/20
        [ "$val" = 20/20 ] && ok=0 || ok=1
        ;;
      tmpsock)
        want=10/10
        [ "$val" = 10/10 ] && ok=0 || ok=1
        ;;
      passwd | tmpdir | nvf | gitstatus | gitcommit)
        want=ok
        [ "$val" = ok ] && ok=0 || ok=1
        ;;
      gitconfig | hooks | include)
        if [ "$mode" = default ]; then want=blocked; else want=allowed; fi
        [ "$val" = "$want" ] && ok=0 || ok=1
        ;;
      pids)
        if [ "$mode" = default ]; then
          want='< 20'
          [ "$val" -lt 20 ] && ok=0 || ok=1
        else
          want='> 50'
          [ "$val" -gt 50 ] && ok=0 || ok=1
        fi
        ;;
      userns)
        want=blocked
        [ "$val" = blocked ] && ok=0 || ok=1
        ;;
      storeowner)
        printf 'INFO  %-8s %-44s %s (spec F6, K1)\n' "$mode" "$key" "$val"
        continue
        ;;
      *) continue ;;
    esac
    check "$mode" "${key#hidden:}" "$val" "$want" "$ok"
  done <"$out"
  # A default run that printed no expectations at all is a failure too.
  grep -q '^nix=' "$out" || check "$mode" "probe output" "missing" "key=value lines" 1
}

startup_ms() { # command... -> milliseconds for one run
  local t0
  t0=$(date +%s%N)
  (cd "$proj" && "$@") >/dev/null 2>&1 || true
  echo $((($(date +%s%N) - t0) / 1000000))
}

printf 'kernel %s, %s, wrapper %s, profile %s\n' "$(uname -r)" \
  "$(nono --version 2>&1 | head -1)" "$(command -v "$wrapper")" "$profile"
run_mode default ""
run_mode relaxed git,pid
nono_ms=$(startup_ms nono run --profile "$profile" --allow-cwd -- true)
wrap_ms=$(startup_ms env AI_SANDBOX_RELAX= "$wrapper" --open-urls-profile "$profile" -- \
  nono run --profile "$profile" --allow-cwd -- true)
printf 'INFO  startup: nono only %s ms, with isolation %s ms (spec: overhead < 500 ms)\n' \
  "$nono_ms" "$wrap_ms"

if [ "$fails" -gt 0 ]; then
  printf '%s FAIL line(s)\n' "$fails"
  exit 1
fi
echo "all PASS"
