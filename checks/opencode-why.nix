# The owner's criterion for the opencode profiles, asked of the real nono (./nono-why.nix): a
# sandboxed opencode cannot write what an unsandboxed Claude Code or Codex executes, nor read
# Claude Code's config, nor reach the sandboxed Claude Code's dir. `nono why` answers `denied`
# for ~/.claude (settings, hooks, credentials), ~/.claude.json, ~/.codex and ~/.claude-sandbox,
# `allowed` for opencode's own config and for its own Claude Code config dir, and read but not
# write on the nono plugin in the pack store; for the harness, its GPU twin and the opencode-web
# service. Then a run of the harness and one of the service show the Claude Code config dir
# reaching the session from the base.
{
  pkgs,
  lib,
  render,
}: let
  dir = ".local/share/opencode/claude";
in
  import ./nono-why.nix {inherit pkgs lib render;} {
    name = "opencode-why";
    profiles = ["opencode-claude" "opencode-claude-gpu" "opencode-web"];
    cases = [
      [".claude/settings.json" "write" "denied"]
      [".claude/settings.json" "read" "denied"]
      [".claude/CLAUDE.md" "read" "denied"]
      [".claude/hooks/x.sh" "write" "denied"]
      [".claude/.credentials.json" "readwrite" "denied"]
      [".claude.json" "write" "denied"]
      [".codex/config.toml" "write" "denied"]
      [".codex/config.toml" "read" "denied"]
      [".claude-sandbox/settings.json" "write" "denied"]
      [".claude-sandbox/.credentials.json" "read" "denied"]
      [".config/opencode/opencode.jsonc" "write" "allowed"]
      ["${dir}/.credentials.json" "readwrite" "allowed"]
      ["${dir}/.claude.json" "write" "allowed"]
      # the nono plugin opencode loads (linked from ~/.config/opencode/plugins): readable, never writable
      [".config/nono/packages/nolabs-ai/opencode/plugin/nono-sandbox.ts" "read" "allowed"]
      [".config/nono/packages/nolabs-ai/opencode/plugin/nono-sandbox.ts" "write" "denied"]
    ];
    # what the profiles grant must exist, or nono drops the grant and an `allowed` case fails
    # for the wrong reason; ~/.claude, ~/.codex and ~/.claude-sandbox exist (and every case
    # path, ./nono-why.nix), so a `denied` is nono's answer on a real directory or file
    dirs = [
      ".claude"
      ".codex"
      ".claude-sandbox"
      ".opencode"
      ".config/opencode"
      ".cache/opencode"
      ".cache/opencode-web"
      ".local/share/opencode"
      ".local/share/opentui"
      ".local/state/opencode"
      dir
      "projects"
    ];
    # the harness and the long-running service, the one that keeps a login in use
    envProfiles = ["opencode-claude" "opencode-web"];
    envHome.CLAUDE_CONFIG_DIR = dir;
  }
