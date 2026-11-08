# The registry packs ai-sandbox re-bases instead of extending (pure; used by the module, the
# render and the checks). Keyed by pack: its profiles extend the base named here, not the
# pack. A base is the pack's own `policy.json`, vendored byte for byte at the version
# scripts/packs pins (`vendored-packs`), minus the pack's grants on the harness's own
# configuration, which an unsandboxed run of that harness executes (hooks, plugins, MCP
# servers). nono's `extends` only adds, so a profile that extends the pack can never drop
# them: the base is the pack's profile without them, extending `default` as the pack does.
# One transform (mkBase) for every base; each entry states only what it drops and adds.
{lib}: let
  mkBase = {
    pack,
    version,
    sha256,
    file,
    name,
    # what the base drops from the pack's `filesystem.allow` and `filesystem.allow_file`
    dropAllow,
    dropFiles ? [],
    # what it adds to `filesystem.allow`
    addAllow ? [],
    # pack dir -> the base's `environment.set_vars` (the pack sets no environment)
    setVars ? (_: {}),
    # made 0700 by the activation and the installer (install/dirs), a symlink refused: nono
    # drops a grant on a path that does not exist, and resolves one that is a link
    dirs ? [],
    # the modification notice's list of changes (Apache-2.0 4(b); vendor/README.md has them all)
    changes,
  }: let
    v = lib.importJSON file;
    fs = v.filesystem;
    # the pack store, where the pack's session hook (and a plugin) stays: `$PACK_DIR` is
    # expanded for store profiles only
    packDir = "$NONO_PACKAGES/${pack}";
    sv = setVars packDir;
  in
    # The shape the transform relies on; a re-vendor that changes it fails here, by name.
    assert lib.assertMsg (v.extends == "default") "bases.nix: ${pack}'s policy.json no longer extends default";
    assert lib.assertMsg (lib.all (x: lib.elem x fs.allow) dropAllow) "bases.nix: ${pack}'s policy.json no longer allows ${toString dropAllow}";
    assert lib.assertMsg (lib.all (x: lib.elem x (fs.allow_file or [])) dropFiles) "bases.nix: ${pack}'s policy.json no longer allows the files ${toString dropFiles}";
    assert lib.assertMsg (!(v ? environment)) "bases.nix: ${pack}'s policy.json now sets an environment";
    assert lib.assertMsg (lib.hasPrefix "$PACK_DIR/" v.session_hooks.before.script) "bases.nix: ${pack}'s session hook is no longer under $PACK_DIR"; {
      inherit name version sha256 file dirs;
      profile =
        v
        // {
          extends = ["default"];
          # Apache-2.0 4(b): the modified file says so (vendor/README.md lists the changes)
          meta = {
            inherit name;
            description = "Modified by ai-sandbox from the ${pack} ${version} profile (Apache-2.0): ${changes}; see modules/home-manager/vendor/README.md";
          };
          filesystem =
            fs
            // {allow = lib.subtractLists dropAllow fs.allow ++ addAllow;}
            // lib.optionalAttrs (fs ? allow_file) {allow_file = lib.subtractLists dropFiles fs.allow_file;};
          session_hooks =
            v.session_hooks
            // {
              before = v.session_hooks.before // {script = packDir + lib.removePrefix "$PACK_DIR" v.session_hooks.before.script;};
            };
        }
        // lib.optionalAttrs (sv != {}) {environment.set_vars = sv;};
    };
in {
  # nolabs-ai/claude: rw on all of `$HOME/.claude` and on `$HOME/.claude.json` let a sandboxed
  # agent plant a hook or an MCP server that the user's unsandboxed Claude Code runs later.
  # Claude Code's credential refresh writes a temporary file next to the credentials and
  # renames it, so no grant narrower than the whole directory keeps a login alive. The
  # sandboxed Claude Code therefore gets a config dir of its own (`CLAUDE_CONFIG_DIR` moves
  # `~/.claude` and `~/.claude.json` there), logs in once inside it and never shares it with an
  # unsandboxed run; the base grants nothing under `$HOME/.claude`, not even read. The pack's
  # nono plugin loads from the pack store, read-only (`CLAUDE_CODE_PLUGIN_DIRS`, Claude Code
  # >= 2.1.280), and its session hook runs from there too.
  "nolabs-ai/claude" = let
    dir = "$HOME/.claude-sandbox";
  in
    mkBase {
      pack = "nolabs-ai/claude";
      version = "0.1.4";
      sha256 = "7605ee6226e4c452587c3663b6b00b9b0609fa2c27ceb961abd7d3a7ed4ab8a0";
      file = ./vendor/nolabs-ai-claude.policy.json;
      name = "ai-sandbox-claude";
      dropAllow = ["$HOME/.claude"];
      dropFiles = ["$HOME/.claude.json" "$HOME/.claude.json.lock" "$HOME/.claude.lock"];
      addAllow = [dir];
      setVars = packDir: {
        CLAUDE_CONFIG_DIR = dir;
        CLAUDE_CODE_PLUGIN_DIRS = packDir;
      };
      dirs = [dir];
      changes = "no ~/.claude grants, an own config dir";
    };

  # nolabs-ai/opencode: rw on all of `$HOME/.claude` and `$HOME/.codex`, the config of two other
  # harnesses, let a sandboxed opencode plant a hook, a plugin or an MCP server that the
  # user's unsandboxed Claude Code or Codex runs later. The base drops both. opencode reaches
  # Claude through Claude Code's credentials (a plugin such as opencode-claude-auth reads them
  # from `CLAUDE_CONFIG_DIR`, refreshes them and writes them back, or runs `claude` with that
  # dir): the base points it at a Claude Code config dir of opencode's own, inside opencode's
  # data dir, which the pack grants already; every opencode profile shares it, and its login
  # is made once inside the sandbox. opencode reads `~/.claude` too (CLAUDE.md, skills, IDE
  # lock files) and starts without them.
  "nolabs-ai/opencode" = let
    dir = "$HOME/.local/share/opencode/claude";
  in
    mkBase {
      pack = "nolabs-ai/opencode";
      version = "0.1.3";
      sha256 = "88dce4b22eefaaba4a298d28e8d38b14fab5a92d2ec075ac34d4f259d8c87a4a";
      file = ./vendor/nolabs-ai-opencode.policy.json;
      name = "ai-sandbox-opencode";
      dropAllow = ["$HOME/.claude" "$HOME/.codex"];
      setVars = _: {CLAUDE_CONFIG_DIR = dir;};
      dirs = [dir];
      changes = "no ~/.claude or ~/.codex grants, a Claude Code config dir of its own";
    };
}
