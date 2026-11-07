# The owner's criterion for the claude profiles, asked of the real nono: a sandboxed Claude Code
# cannot write what an unsandboxed Claude Code executes. With the profiles of the render (the
# module's output, = profiles/ by `render-profiles`) in a fresh home, `nono why` answers
# `denied` for writes to ~/.claude (settings, hooks, plugins) and ~/.claude.json and for any
# read of ~/.claude, `allowed` for a write in the sandbox's own config dir, and read but not
# write on the nono plugin in the pack store. Then a run shows both reaching the session:
# `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_PLUGIN_DIRS` set from the base, through the leaf.
# No pack store and no network: the bases extend nono's built-in `default`.
{
  pkgs,
  lib,
  render,
}: let
  profiles = ["claude-local" "claude-local-gpu"];
  # path (below the home) -> op -> the verdict nono must give
  cases = [
    [".claude/settings.json" "write" "denied"]
    [".claude/settings.json" "read" "denied"]
    [".claude/hooks/x.sh" "write" "denied"]
    [".claude/plugins/x" "write" "denied"]
    [".claude/.credentials.json" "readwrite" "denied"]
    [".claude.json" "write" "denied"]
    [".claude.json" "read" "denied"]
    [".claude-sandbox/settings.json" "write" "allowed"]
    [".claude-sandbox/.credentials.json" "readwrite" "allowed"]
    # the nono plugin Claude Code loads (CLAUDE_CODE_PLUGIN_DIRS): readable, never writable
    [".config/nono/packages/nolabs-ai/claude/hooks/hooks.json" "read" "allowed"]
    [".config/nono/packages/nolabs-ai/claude/hooks/hooks.json" "write" "denied"]
    [".config/nono/packages/nolabs-ai/claude/hooks/x.sh" "write" "denied"]
  ];
in
  pkgs.runCommand "claude-why" {nativeBuildInputs = [pkgs.nono pkgs.jq pkgs.coreutils];} ''
    # beside the home, not around it: nono refuses a grant ($TMPDIR) that holds its own state
    export HOME=$PWD/home XDG_CONFIG_HOME=$PWD/home/.config XDG_CACHE_HOME=$PWD/home/.cache TMPDIR=$PWD/tmp
    mkdir -p "$XDG_CONFIG_HOME/nono/profiles" "$HOME/.claude" "$HOME/.claude-sandbox" "$XDG_CACHE_HOME/claude" "$TMPDIR" \
      "$XDG_CONFIG_HOME/nono/packages/nolabs-ai/claude/hooks"
    # the pack store must exist, or nono drops its grants and the plugin-dir cases prove nothing
    : >"$XDG_CONFIG_HOME/nono/packages/nolabs-ai/claude/hooks/hooks.json"
    cp ${render.tree}/profiles/*.json "$XDG_CONFIG_HOME/nono/profiles/"
    fail=0
    ${lib.concatMapStrings (p:
      lib.concatMapStrings (c: let
        path = lib.elemAt c 0;
        op = lib.elemAt c 1;
        want = lib.elemAt c 2;
      in ''
        got=$(nono why --json --profile ${p} --path "$HOME/${path}" --op ${op} 2>why.err | jq -r .status) || got="error: $(cat why.err)"
        if [ "$got" != ${want} ]; then
          echo "claude-why: nono why --profile ${p} --path ~/${path} --op ${op}: $got, want ${want}" >&2
          fail=1
        fi
      '')
      cases)
    profiles}
    # The session the profile runs: the config dir comes from the base (the leaf does not set it).
    env=$(nono run --profile claude-local -- ${pkgs.coreutils}/bin/env 2>run.err) || {
      echo "claude-why: nono run --profile claude-local failed: $(cat run.err)" >&2
      exit 1
    }
    printf '%s\n' "$env" | grep -qxF "CLAUDE_CONFIG_DIR=$HOME/.claude-sandbox" || {
      echo "claude-why: a claude-local session has no CLAUDE_CONFIG_DIR=$HOME/.claude-sandbox: $(printf '%s\n' "$env" | grep CLAUDE || true)" >&2
      fail=1
    }
    printf '%s\n' "$env" | grep -qxF "CLAUDE_CODE_PLUGIN_DIRS=$XDG_CONFIG_HOME/nono/packages/nolabs-ai/claude" || {
      echo "claude-why: a claude-local session does not load the nono plugin from the pack store: $(printf '%s\n' "$env" | grep CLAUDE || true)" >&2
      fail=1
    }
    [ "$fail" = 0 ] || exit 1
    touch $out
  ''
