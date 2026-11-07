# The registry packs ai-sandbox re-bases instead of extending (pure; used by the module, the
# render and the checks). Keyed by pack: its profiles extend the base named here, not the
# pack. A base is the pack's own `policy.json`, vendored byte for byte at the version
# scripts/packs pins (`vendored-packs`), minus the pack's grants on the harness's own
# configuration, which an unsandboxed run of that harness executes (hooks, plugins, MCP
# servers). nono's `extends` only adds, so a profile that extends the pack can never drop
# them: the base is the pack's profile without them, extending `default` as the pack does.
#
# nolabs-ai/claude: rw on all of `$HOME/.claude` and on `$HOME/.claude.json` let a sandboxed
# agent plant a hook or an MCP server that the user's unsandboxed Claude Code runs later.
# Claude Code's credential refresh writes a temporary file next to the credentials and renames
# it, so no grant narrower than the whole directory keeps a login alive. The sandboxed Claude
# Code therefore gets a config dir of its own (`CLAUDE_CONFIG_DIR` moves `~/.claude` and
# `~/.claude.json` there), logs in once inside it and never shares it with an unsandboxed run;
# the base grants nothing under `$HOME/.claude`, not even read. The pack's nono plugin loads
# from the pack store, read-only (`CLAUDE_CODE_PLUGIN_DIRS`, Claude Code >= 2.1.280), and its
# session hook runs from there too (`$PACK_DIR` is expanded for store profiles only).
{lib}: let
  pack = "nolabs-ai/claude";
  version = "0.1.4";
  file = ./vendor/nolabs-ai-claude.policy.json;
  v = lib.importJSON file;
  dir = "$HOME/.claude-sandbox";
  packDir = "$NONO_PACKAGES/${pack}";
  dropAllow = ["$HOME/.claude"];
  dropFiles = ["$HOME/.claude.json" "$HOME/.claude.json.lock" "$HOME/.claude.lock"];
  notice = "Modified by ai-sandbox from the ${pack} ${version} profile (Apache-2.0): no ~/.claude grants, an own config dir; see modules/home-manager/vendor/README.md";
in
  # The shape the transform relies on; a re-vendor that changes it fails here, by name.
  assert lib.assertMsg (v.extends == "default") "bases.nix: ${pack}'s policy.json no longer extends default";
  assert lib.assertMsg (lib.all (x: lib.elem x v.filesystem.allow) dropAllow) "bases.nix: ${pack}'s policy.json no longer allows ${toString dropAllow}";
  assert lib.assertMsg (lib.all (x: lib.elem x v.filesystem.allow_file) dropFiles) "bases.nix: ${pack}'s policy.json no longer allows the files ${toString dropFiles}";
  assert lib.assertMsg (!(v ? environment)) "bases.nix: ${pack}'s policy.json now sets an environment";
  assert lib.assertMsg (lib.hasPrefix "$PACK_DIR/" v.session_hooks.before.script) "bases.nix: ${pack}'s session hook is no longer under $PACK_DIR"; {
    ${pack} = {
      name = "ai-sandbox-claude";
      inherit version;
      sha256 = "7605ee6226e4c452587c3663b6b00b9b0609fa2c27ceb961abd7d3a7ed4ab8a0";
      inherit file;
      # made 0700 by the activation and the installer (install/dirs): nono drops a grant on a
      # path that does not exist
      dirs = [dir];
      profile =
        v
        // {
          extends = ["default"];
          # Apache-2.0 4(b): the modified file says so (vendor/README.md lists the changes)
          meta = {
            name = "ai-sandbox-claude";
            description = notice;
          };
          filesystem =
            v.filesystem
            // {
              allow = lib.subtractLists dropAllow v.filesystem.allow ++ [dir];
              allow_file = lib.subtractLists dropFiles v.filesystem.allow_file;
            };
          session_hooks =
            v.session_hooks
            // {
              before = v.session_hooks.before // {script = packDir + lib.removePrefix "$PACK_DIR" v.session_hooks.before.script;};
            };
          environment.set_vars = {
            CLAUDE_CONFIG_DIR = dir;
            CLAUDE_CODE_PLUGIN_DIRS = packDir;
          };
        };
    };
  }
