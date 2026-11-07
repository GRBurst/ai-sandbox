# The ai-sandbox-run suite as a function of the wrapper under test: it builds
# real isolations in the build sandbox against fixture sockets under `fx`.
# `W` is the wrapper with every layer, `NOPID` the one without `pid`, `CHECK`
# the URL check, `SHIM` the xdg-open shim, `tokens` the relax tokens the
# wrapper reports. The Nix-built wrappers and the installed portable wrapper run
# the same text.
{
  lib,
  runCommand,
  socat,
  util-linux,
  git,
  coreutils,
  procps,
  gnugrep,
  findutils,
}: {
  name,
  W,
  NOPID,
  CHECK,
  SHIM,
  tokens,
  fx,
  # shell text run first (the portable check installs the wrapper there), and
  # the tools it needs besides the suite's own
  pre ? "",
  extraInputs ? [],
}:
runCommand name {
  nativeBuildInputs = [socat util-linux git coreutils procps gnugrep findutils] ++ extraInputs;
  meta.description = "ai-sandbox-run builds real isolations; layers, relax, git, fail-closed, URL relay";
} ''
  set -euo pipefail
  ${pre}W=${W}
  NOPID=${NOPID}
  CHECK=${CHECK}
  SHIM=${SHIM}
  FX=${fx}
  export FX
  fail() { echo "FAIL: $*" >&2; exit 1; }
  uid=$(id -u)
  mksock() {
    (socat "UNIX-LISTEN:$1,fork" EXEC:true &)
    for _ in $(seq 30); do [ -S "$1" ] && return 0; sleep 0.1; done
    fail "fixture socket $1 did not appear"
  }
  mkdir -p "$FX/run/user/$uid" /tmp/.X11-unix
  mksock "$FX/run/user/$uid/bus"
  mksock "$FX/docker.sock"
  mksock "$FX/system_bus_socket"
  mksock /tmp/.X11-unix/X0
  socats_before=$(pgrep -c -x socat)
  export TMPDIR=$NIX_BUILD_TOP/agent-tmp
  mkdir -p "$TMPDIR"
  vis() { "$W" -- sh -c 'test -S "$1" && echo yes || echo no' _ "$1"; }

  # ---- T1.1: arguments, relax, TMPDIR --------------------------------------
  # case relax-unknown (S3.2, R8)
  rc=0; AI_SANDBOX_RELAX=gti "$W" -- touch "$NIX_BUILD_TOP/ran" 2>err || rc=$?
  [ "$rc" = 2 ] || fail "relax-unknown: exit $rc, want 2"
  grep -q "unknown token 'gti'" err || fail "relax-unknown: message"
  for t in ${lib.escapeShellArgs tokens}; do grep -q "$t" err || fail "relax-unknown: token $t not listed"; done
  [ ! -e "$NIX_BUILD_TOP/ran" ] || fail "relax-unknown: command ran"
  # case relax-announce (S3.1, RF5)
  AI_SANDBOX_RELAX=git,,git,pid, "$W" -- true 2>err
  [ "$(grep -c '^ai-sandbox-run: relaxed:' err)" = 1 ] || fail "relax-announce: not exactly one line"
  grep -qx 'ai-sandbox-run: relaxed: git,pid' err || fail "relax-announce: $(cat err)"
  # case tmpdir-invalid (S4.2)
  rc=0; TMPDIR=rel "$W" -- true 2>err || rc=$?
  [ "$rc" = 1 ] && grep -q TMPDIR err || fail "tmpdir-invalid: relative"
  rc=0; TMPDIR=$NIX_BUILD_TOP/missing "$W" -- true 2>err || rc=$?
  [ "$rc" = 1 ] && grep -q TMPDIR err || fail "tmpdir-invalid: missing"
  rc=0; "$W" --bogus -- true 2>err || rc=$?
  [ "$rc" = 2 ] || fail "unknown option: exit $rc"
  rc=0; AI_SANDBOX_RELAX=browser "$W" -- true 2>err || rc=$?
  [ "$rc" = 2 ] && grep -q open-urls-profile err || fail "browser without profile"
  # case path-unchanged (R3)
  got=$("$W" -- sh -c 'printf %s "$PATH"')
  [ "''${got%%:*}" = "$(dirname "$SHIM")" ] || fail "path-unchanged: shim not first"
  [ "''${got#*:}" = "$PATH" ] || fail "path-unchanged: rest of PATH altered"

  # ---- T1.2: hiding (R2) — tmp relaxed so /tmp does not mask fixtures ---
  export AI_SANDBOX_RELAX=tmp
  [ "$(vis "$FX/run/user/$uid/bus")" = no ] || fail "hide-session"
  [ "$(vis "$FX/docker.sock")" = no ] || fail "hide-docker"
  [ "$(vis "$FX/system_bus_socket")" = no ] || fail "hide-system"
  AI_SANDBOX_RELAX=tmp,session; [ "$(vis "$FX/run/user/$uid/bus")" = yes ] || fail "relax-session"
  [ "$(vis "$FX/docker.sock")" = no ] || fail "relax-session leaked docker"
  AI_SANDBOX_RELAX=tmp,docker; [ "$(vis "$FX/docker.sock")" = yes ] || fail "relax-docker"
  AI_SANDBOX_RELAX=tmp,system; [ "$(vis "$FX/system_bus_socket")" = yes ] || fail "relax-system"
  unset AI_SANDBOX_RELAX
  # case hide-absent: an absent socket path is skipped, not created on the host
  # (bwrap would create the mount point through the --dev-bind / /)
  [ ! -e "$FX/absent.sock" ] || fail "hide-absent: $FX/absent.sock created on the host"
  # case tmpdir-socket (S1.4): TMPDIR under the tmpfs'd runtime dir survives
  mkdir -p "$FX/run/user/$uid/agent/tmp"
  n=$(TMPDIR=$FX/run/user/$uid/agent/tmp AI_SANDBOX_RELAX=tmp "$W" -- sh -c '
    s=$TMPDIR/p.sock; socat "UNIX-LISTEN:$s,fork" EXEC:true >/dev/null 2>&1 & sp=$!; sleep 0.3; ok=0
    for _ in $(seq 10); do socat -u OPEN:/dev/null "UNIX-CONNECT:$s" && ok=$((ok+1)); done
    kill $sp; echo $ok')
  [ "$n" = 10 ] || fail "tmpdir-socket: $n/10"
  # case env-hidden-unset: variables naming a path the isolation hides are
  # removed (an agent gets "unset", not a dangling socket path); variables
  # naming a survivor, or the runtime dir itself, are kept.
  envprobe() {
    env TMPDIR="$FX/run/user/$uid/agent/tmp" \
      SSH_AUTH_SOCK="$FX/run/user/$uid/gnupg/S.gpg-agent.ssh" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$FX/run/user/$uid/bus" \
      TMP_SOCK=/tmp/ssh-x/agent.1 \
      KEEP_SURVIVOR="$FX/run/user/$uid/agent/tmp/s.sock" \
      XDG_RUNTIME_DIR="$FX/run/user/$uid" \
      KEEP_OTHER=/nix/store \
      "$W" -- env 2>/dev/null
  }
  has_var() { printf '%s\n' "$1" | grep -q "^$2="; }
  # tmp relaxed: the fixture runtime dir lives under /tmp (as in T1.2).
  e=$(AI_SANDBOX_RELAX=tmp envprobe)
  for v in SSH_AUTH_SOCK DBUS_SESSION_BUS_ADDRESS; do
    ! has_var "$e" $v || fail "env-hidden-unset: $v kept"
  done
  for v in KEEP_SURVIVOR XDG_RUNTIME_DIR KEEP_OTHER TMP_SOCK TMPDIR; do
    has_var "$e" $v || fail "env-hidden-unset: $v removed"
  done
  ! has_var "$(envprobe)" TMP_SOCK || fail "env-hidden-unset: TMP_SOCK kept with the tmp layer on"
  has_var "$(AI_SANDBOX_RELAX=session,tmp envprobe)" SSH_AUTH_SOCK || fail "env-hidden-unset: relax session must keep SSH_AUTH_SOCK"

  # ---- T1.3: pid, userns, tmp, x11 (S2.1, S2.4, S2.5, S6.1, RF2) -------------
  # The builder may itself be pid 1 of the build's pid namespace, so a host
  # pid number can collide with one inside; compare namespaces and look for a
  # marker process instead.
  host_ns=$(readlink /proc/self/ns/pid)
  sleep 3001 & marker=$!
  seen='pgrep -f "^sleep 3001$" >/dev/null'
  "$W" -- sh -c '[ "$(readlink /proc/self/ns/pid)" != "$1" ] && ! '"$seen" _ "$host_ns" || fail "pid: host pid visible"
  AI_SANDBOX_RELAX=pid "$W" -- sh -c "$seen" || fail "relax-pid"
  "$NOPID" -- sh -c "$seen" || fail "layers option: pid absent from layers must stay off"
  kill "$marker"
  "$W" -- sh -c '! unshare -U true 2>/dev/null' || fail "userns: nested namespace allowed"
  AI_SANDBOX_RELAX=userns "$W" -- unshare -U true || fail "relax-userns"
  touch /tmp/hostfile
  "$W" -- sh -c '[ ! -e /tmp/hostfile ] && touch /tmp/leak' || fail "tmp-private: host /tmp visible"
  [ ! -e /tmp/leak ] || fail "tmp-private: write leaked to host /tmp"
  mkdir -p /tmp/agent-tmp && echo host > /tmp/agent-tmp/f
  TMPDIR=/tmp/agent-tmp "$W" -- sh -c 'grep -qx host "$TMPDIR/f" && echo in > "$TMPDIR/g"' || fail "tmpdir-under-tmp: not visible"
  grep -qx in /tmp/agent-tmp/g || fail "tmpdir-under-tmp: write not on host"
  mkdir -p /tmp/proj && (cd /tmp/proj && "$W" -- sh -c 'echo x > inproj') || fail "pwd-under-tmp: project hidden"
  [ -e /tmp/proj/inproj ] || fail "pwd-under-tmp: write lost"
  "$W" --x11 -- sh -c 'test -S /tmp/.X11-unix/X0 && [ ! -e /tmp/hostfile ]' || fail "x11: socket dir not bound or /tmp leaked"
  "$W" -- sh -c '! test -e /tmp/.X11-unix/X0' || fail "x11: visible without --x11"

  # ---- T1.4: git (S2.2, S2.3, S5.1, RF1, RF3, RF4) ---------------------------
  mkrepo() {
    rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q
    git -C "$1" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
  }
  R=$NIX_BUILD_TOP/repo; mkrepo "$R"; mkdir -p "$R/.githooks"
  git -C "$R" config core.hooksPath .githooks
  (cd "$R" && "$W" -- sh -c '! (echo x >> .git/config) 2>/dev/null') || fail "git-ro: .git/config writable"
  (cd "$R" && "$W" -- sh -c '! touch .git/hooks/pre-commit 2>/dev/null') || fail "git-ro: hooks writable"
  (cd "$R" && "$W" -- sh -c '! touch .githooks/pre-commit 2>/dev/null') || fail "git-hookspath-in-tree"
  (cd "$R" && "$W" -- git -c user.email=a@b -c user.name=a commit -q --allow-empty -m in) || fail "git-ro: commit broken"
  (cd "$R" && AI_SANDBOX_RELAX=git "$W" -- sh -c 'touch .git/hooks/x') || fail "relax-git"
  rm -f "$R/.git/hooks/x"
  mkdir -p "$NIX_BUILD_TOP/outhooks"; git -C "$R" config core.hooksPath "$NIX_BUILD_TOP/outhooks"
  (cd "$R" && "$W" -- touch "$NIX_BUILD_TOP/outhooks/x") || fail "git-hookspath-out-of-tree: bound read-only"
  git -C "$R" config core.hooksPath .
  (cd "$R" && "$W" -- touch newfile) || fail "git-hookspath-root: project made read-only"
  rm -f "$R/newfile"
  # case git-symlinked-cwd: the project reached through a symlink (logical
  # $PWD) keeps its in-tree hooks dir read-only
  git -C "$R" config core.hooksPath .githooks
  ln -s "$R" "$NIX_BUILD_TOP/repolink"
  (cd "$NIX_BUILD_TOP/repolink" && "$W" -- sh -c '! touch .githooks/pre-commit 2>/dev/null') || fail "git-symlinked-cwd: .githooks writable"
  # case git-no-includes (D10): the wrapper reads the repository's config file
  # alone. An include that overrides core.hooksPath must not unprotect the
  # in-tree hooks dir; a plain `git -C "$PWD" config` would follow it.
  git -C "$R" config core.hooksPath .githooks
  printf '[core]\n\thooksPath = %s\n' "$NIX_BUILD_TOP/outhooks" > "$NIX_BUILD_TOP/inc"
  git -C "$R" config include.path "$NIX_BUILD_TOP/inc"
  (cd "$R" && "$W" -- sh -c '! touch .githooks/pre-commit 2>/dev/null') || fail "git-no-includes: include unprotected .githooks"
  git -C "$R" config --unset include.path; git -C "$R" config --unset core.hooksPath
  # case git-include-target-ro (T1.4b): in-tree include targets are config too
  # (they could set core.fsmonitor for the human's next git status): nested,
  # includeIf with a space in the condition, and a hooksPath they set.
  printf '[include]\n\tpath = .gitconfig-nested\n' > "$R/.gitconfig-local"
  printf '[core]\n\thooksPath = .inchooks\n' > "$R/.gitconfig-nested"
  : > "$R/.gitconfig-cond"; mkdir -p "$R/.inchooks"
  git -C "$R" config include.path ../.gitconfig-local
  git -C "$R" config 'includeIf.gitdir:/no such dir/.path' ../.gitconfig-cond
  for f in .gitconfig-local .gitconfig-nested .gitconfig-cond; do
    (cd "$R" && "$W" -- sh -c '! (echo x >> "$1") 2>/dev/null' _ "$f") || fail "git-include-target-ro: $f writable"
  done
  (cd "$R" && "$W" -- sh -c '! touch .inchooks/pre-commit 2>/dev/null') || fail "git-include-target-ro: included hooksPath writable"
  git -C "$R" config --unset include.path; git -C "$R" config --remove-section 'includeIf.gitdir:/no such dir/'
  rm -rf "$R/.gitconfig-local" "$R/.gitconfig-nested" "$R/.gitconfig-cond" "$R/.inchooks"
  printf '#!/bin/sh\ntouch %s\n' "$NIX_BUILD_TOP/fsmonitor-ran" > "$NIX_BUILD_TOP/fsm"; chmod +x "$NIX_BUILD_TOP/fsm"
  git -C "$R" config core.fsmonitor "$NIX_BUILD_TOP/fsm"
  (cd "$R" && "$W" -- true)
  [ ! -e "$NIX_BUILD_TOP/fsmonitor-ran" ] || fail "git-no-exec: wrapper executed the repo's fsmonitor"
  git -C "$R" config --unset core.fsmonitor
  # case git-dir-extra: a git dir named with --git-dir (a variant's gitDirs, e.g. a bare
  # repository the agent commits to): hooks, config and info read-only, objects writable;
  # a relative, missing, hook-less or commondir'd one refused.
  B=$NIX_BUILD_TOP/bare.git; git init -q --bare "$B"; mkdir -p "$B/hooks" "$B/info"
  "$W" --git-dir "$B" -- sh -c '! touch "$1/hooks/x" 2>/dev/null' _ "$B" || fail "git-dir: hooks writable"
  "$W" --git-dir "$B" -- sh -c '! (echo x >> "$1/config") 2>/dev/null' _ "$B" || fail "git-dir: config writable"
  "$W" --git-dir "$B" -- sh -c '! touch "$1/info/x" 2>/dev/null' _ "$B" || fail "git-dir: info writable"
  "$W" --git-dir "$B" -- sh -c 'touch "$1/objects/x" && rm "$1/objects/x"' _ "$B" || fail "git-dir: objects not writable"
  "$W" -- sh -c 'touch "$1/hooks/x" && rm "$1/hooks/x"' _ "$B" || fail "git-dir: held without --git-dir"
  (AI_SANDBOX_RELAX=git "$W" --git-dir "$B" -- sh -c 'touch "$1/hooks/x" && rm "$1/hooks/x"' _ "$B") || fail "git-dir: relax-git"
  git_dir_refused() {
    local want=$1 rc=0; shift
    "$W" "$@" -- touch "$NIX_BUILD_TOP/gd-ran" 2>err || rc=$?
    [ "$rc" = 1 ] || fail "git-dir-refused ($want): exit $rc"
    grep -q "$want" err || fail "git-dir-refused ($want): $(cat err)"
    [ ! -e "$NIX_BUILD_TOP/gd-ran" ] || fail "git-dir-refused ($want): command ran"
  }
  git_dir_refused 'must be an absolute path' --git-dir bare.git
  git_dir_refused 'does not exist' --git-dir "$NIX_BUILD_TOP/no-such.git"
  git_dir_refused 'not a git directory' --git-dir "$NIX_BUILD_TOP"
  rm -rf "$B/hooks"; git_dir_refused 'no hooks directory' --git-dir "$B"; mkdir "$B/hooks"
  echo "$R/.git" > "$B/commondir"; git_dir_refused 'has a commondir file' --git-dir "$B"; rm "$B/commondir"
  # case git-dir-worktrees: a linked worktree of the git dir: its config.worktree,
  # commondir and gitdir read-only (git reads the first two for that worktree's
  # config), its index writable.
  WT=$B/worktrees/wt1; mkdir -p "$WT"; : > "$WT/config.worktree"
  echo ../.. > "$WT/commondir"; echo "$NIX_BUILD_TOP/wt1/.git" > "$WT/gitdir"
  for f in config.worktree commondir gitdir; do
    "$W" --git-dir "$B" -- sh -c '! (echo x >> "$1") 2>/dev/null' _ "$WT/$f" || fail "git-dir-worktrees: $f writable"
  done
  "$W" --git-dir "$B" -- sh -c 'touch "$1/index" && rm "$1/index"' _ "$WT" || fail "git-dir-worktrees: index not writable"
  # case git-dir-config-worktree: a hooksPath and an include set in the git dir's
  # config.worktree are held read-only too.
  mkdir -p "$B/wthooks"; : > "$B/wtinc"
  printf '[core]\n\thooksPath = %s\n[include]\n\tpath = wtinc\n' "$B/wthooks" > "$B/config.worktree"
  "$W" --git-dir "$B" -- sh -c '! touch "$1/wthooks/x" 2>/dev/null' _ "$B" || fail "git-dir-config-worktree: hooksPath writable"
  "$W" --git-dir "$B" -- sh -c '! (echo x >> "$1/wtinc") 2>/dev/null' _ "$B" || fail "git-dir-config-worktree: include writable"
  # case git-dir-core-worktree: a relative hooksPath resolves against
  # core.worktree (here set in config.worktree), not the git dir.
  mkdir -p "$B/tree/hk"
  printf '[core]\n\tworktree = %s\n\thooksPath = hk\n' "$B/tree" > "$B/config.worktree"
  "$W" --git-dir "$B" -- sh -c '! touch "$1/tree/hk/x" 2>/dev/null' _ "$B" || fail "git-dir-core-worktree: hooksPath writable"
  rm -rf "$B/worktrees" "$B/config.worktree" "$B/wthooks" "$B/wtinc" "$B/tree"
  mkdir -p /tmp/tdanc; T2=/tmp/tdanc; mkrepo "$T2/repo"
  (cd "$T2/repo" && TMPDIR=$T2 "$W" -- sh -c '! (echo x >> .git/config) 2>/dev/null') || fail "git-ro-under-tmpdir (RF1)"
  before=$(cd "$R" && find . | sort; git -C "$R" status --porcelain --ignored)
  (cd "$R" && "$W" -- true) && (cd "$R" && "$W" -- true)
  after=$(cd "$R" && find . | sort; git -C "$R" status --porcelain --ignored)
  [ "$before" = "$after" ] || fail "no-side-effects: project changed"

  # ---- T1.5: fail closed (S4.1) ---------------------------------------------
  rc=0; "$W" -- "$W" --nono-alias pi_nono -- touch "$NIX_BUILD_TOP/inner-ran" 2>err || rc=$?
  [ "$rc" = 126 ] || fail "fail-closed: exit $rc, want 126"
  grep -q "run 'pi_nono'" err || fail "fail-closed: hint missing"
  [ ! -e "$NIX_BUILD_TOP/inner-ran" ] || fail "fail-closed: command ran"

  # ---- T2.1: url-check table (R12) ------------------------------------------
  export AI_SANDBOX_OPEN_URLS='{"allow_origins":["https://github.com","https://claude.ai"],"allow_localhost":true}'
  for u in https://github.com https://github.com/x?y=1 https://CLAUDE.AI/ http://localhost:8080/cb http://127.0.0.1/; do
    "$CHECK" "$u" || fail "url-check: must allow $u"
  done
  for u in https://example.com 'https://claude.ai@evil.example/' https://claude.ai.evil.example/ \
           http://github.com https://github.com:443/ 'https://github.com/a b' javascript:alert file:///etc/passwd ""; do
    if "$CHECK" "$u"; then fail "url-check: must refuse '$u'"; fi
  done
  if AI_SANDBOX_OPEN_URLS='{"allow_origins":[],"allow_localhost":false}' "$CHECK" http://localhost/; then
    fail "url-check: localhost not allowed"
  fi
  unset AI_SANDBOX_OPEN_URLS

  # ---- T2.2: shim refuses by default (S2.6) ---------------------------------
  rc=0; "$W" -- xdg-open https://github.com 2>err || rc=$?
  [ "$rc" = 1 ] && grep -q 'https://github.com' err && grep -q 'AI_SANDBOX_RELAX=browser' err || fail "shim-refuses"
  [ ! -e "$FX/opened" ] || fail "shim-refuses: opened"

  # ---- T2.3: relay (S3.5, S3.6, S5.2) ---------------------------------------
  AI_SANDBOX_RELAX=browser "$W" --open-urls-profile p -- xdg-open https://github.com || fail "relay-allows"
  # the relay detaches the opener (setsid -f): wait for it
  for _ in $(seq 30); do [ -e "$FX/opened" ] && break; sleep 0.1; done
  grep -qx https://github.com "$FX/opened" || fail "relay-allows: not opened"
  rc=0; AI_SANDBOX_RELAX=browser "$W" --open-urls-profile p -- xdg-open https://example.com 2>err || rc=$?
  [ "$rc" = 1 ] && grep -q refused err && ! grep -q example "$FX/opened" || fail "relay-refuses"
  sleep 0.3
  [ "$(pgrep -c -x socat)" = "$socats_before" ] || fail "relay-cleanup: relay still running"
  ! ls "$TMPDIR" | grep -q '^ai-sandbox-url\.' || fail "relay-cleanup: relay dir left"

  touch $out
''
