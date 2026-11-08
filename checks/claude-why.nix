# The owner's criterion for the claude profiles, asked of the real nono (./nono-why.nix): a
# sandboxed Claude Code cannot write what an unsandboxed Claude Code executes. `nono why`
# answers `denied` for writes to ~/.claude (settings, hooks, plugins) and ~/.claude.json and
# for any read of ~/.claude, `allowed` for a write in the sandbox's own config dir, and read but
# not write on the nono plugin in the pack store. Then a run shows both variables reaching the
# session: `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_PLUGIN_DIRS` set from the base, through the leaf.
{
  pkgs,
  lib,
  render,
}:
import ./nono-why.nix {inherit pkgs lib render;} {
  name = "claude-why";
  profiles = ["claude-local" "claude-local-gpu"];
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
  # every case path exists too (./nono-why.nix): the pack store, or nono drops its grants and
  # the plugin-dir cases prove nothing; the files under ~/.claude, or a file grant goes unseen
  dirs = [".claude" ".claude/plugins" ".claude-sandbox" ".cache/claude"];
  envProfiles = ["claude-local"];
  envHome = {
    CLAUDE_CONFIG_DIR = ".claude-sandbox";
    CLAUDE_CODE_PLUGIN_DIRS = ".config/nono/packages/nolabs-ai/claude";
  };
}
