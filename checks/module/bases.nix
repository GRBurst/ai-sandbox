# The ai-sandbox bases (modules/home-manager/bases.nix) as the module emits them, over the
# standalone fixtures of ./lib.nix; wired by ./default.nix as ai-sandbox-bases. The base of
# nolabs-ai/claude is restated here, not read back from bases.nix: the vendored pack profile
# minus every grant on Claude Code's own config, plus a config dir of its own.
{
  lib,
  helpers,
}: let
  inherit (helpers) mkAssertionCheck aiFixtureWith aiNoNvf aiEmittedProfiles aiBasePack;
  baseName = "ai-sandbox-claude";
  vendored = lib.importJSON ../../modules/home-manager/vendor/nolabs-ai-claude.policy.json;
  vendoredVersion = (import ../../modules/home-manager/bases.nix {inherit lib;})."nolabs-ai/claude".version;
  dir = "$HOME/.claude-sandbox";
  packDir = "$NONO_PACKAGES/nolabs-ai/claude";
  droppedFiles = ["$HOME/.claude.json" "$HOME/.claude.json.lock" "$HOME/.claude.lock"];

  on = aiNoNvf.config;
  emitted = aiEmittedProfiles on;
  base = emitted.${baseName} or {};

  # a claude variant, and a harness of another name on the claude pack (as a service is)
  wider =
    (aiFixtureWith {
      programs.aiSandbox.variants.claude_x = {
        harness = "claude";
        suffix = "x";
        allow = ["$HOME/src/x"];
      };
      programs.aiSandbox.harnesses.svc = {
        profileName = "svc-test";
        pack = "nolabs-ai/claude";
      };
    })
    .config;
  noClaude = (aiFixtureWith {programs.aiSandbox.harnesses.claude.enable = false;}).config;
  svcOnly =
    (aiFixtureWith {
      programs.aiSandbox.harnesses.claude.enable = false;
      programs.aiSandbox.harnesses.svc = {
        profileName = "svc-test";
        pack = "nolabs-ai/claude";
      };
    })
    .config;
  off = (aiFixtureWith {programs.aiSandbox.enable = false;}).config;
  editor = (aiFixtureWith {programs.aiSandbox.editor.enable = true;}).config;

  # Every path a profile grants (all `filesystem` lists but `deny`; `keys` narrows them), `~`
  # spelled `$HOME`.
  grantsIn = keys: p:
    map (e: let
      g =
        if lib.isString e
        then e
        else e.path or "";
    in
      if lib.hasPrefix "~" g
      then "$HOME" + lib.removePrefix "~" g
      else g)
    (lib.concatLists (lib.mapAttrsToList (k: v: lib.optionals (k != "deny" && keys k && lib.isList v) v) (p.filesystem or {})));
  grants = grantsIn (_: true);
  writes = grantsIn (k: lib.elem k ["allow" "allow_file"]);
  # Claude Code's own config: the directory and `.claude.json` (+ locks); `$HOME/.claude-sandbox` is not.
  # `${HOME}` and `~` are spelled `$HOME`; the home itself (or `/`) holds `~/.claude` too.
  claudeOwn = g0: let
    g = lib.removeSuffix "/" (builtins.replaceStrings ["\${HOME}"] ["$HOME"] g0);
  in
    g == "" || g == "$HOME" || g == "$HOME/.claude" || lib.hasPrefix "$HOME/.claude/" g || lib.hasPrefix "$HOME/.claude." g;

  # nono's pack store and config (the plugin dir and the session hook run from there, the hook
  # unsandboxed), or a dir holding them; the pack's own `profile-drafts` is the one write it keeps.
  nonoRoots = ["$NONO_PACKAGES" "$NONO_CONFIG" "$XDG_CONFIG_HOME/nono" "$HOME/.config/nono"];
  nonoOwn = g0: let
    g = lib.removeSuffix "/" (builtins.replaceStrings ["\${HOME}" "\${XDG_CONFIG_HOME}"] ["$HOME" "$XDG_CONFIG_HOME"] g0);
  in
    g
    != "$NONO_CONFIG/profile-drafts"
    && (lib.elem g (["" "$HOME" "$HOME/.config" "$XDG_CONFIG_HOME"] ++ nonoRoots)
      || lib.any (r: lib.hasPrefix "${r}/" g) nonoRoots);

  # The profiles of the claude pack in a home: the base and every profile extending it.
  family = h: lib.filterAttrs (n: p: n == baseName || (p.extends or null) == [baseName]) (aiEmittedProfiles h);

  dirsOf = h: h.programs.aiSandbox.internal.activationDirs;
  reclaim = h: h.home.activation.nonoProfileReclaim.data or "";
  kept = ["extends" "meta" "filesystem" "session_hooks" "environment"];
in
  mkAssertionCheck "ai-sandbox-bases" [
    {
      # P-verbatim: outside the named keys the base is the vendored pack profile; inside them,
      # exactly the stated transform.
      condition =
        emitted ? ${baseName}
        && removeAttrs base kept == removeAttrs vendored kept
        && removeAttrs base.filesystem ["allow" "allow_file"] == removeAttrs vendored.filesystem ["allow" "allow_file"]
        && base.filesystem.allow == lib.subtractLists ["$HOME/.claude"] vendored.filesystem.allow ++ [dir]
        && base.filesystem.allow_file == lib.subtractLists droppedFiles vendored.filesystem.allow_file
        && base.session_hooks == lib.recursiveUpdate vendored.session_hooks {before.script = "${packDir}/bin/ensure-dirs.sh";}
        && base.extends == ["default"]
        && lib.attrNames base.meta == ["description" "name"]
        && base.meta.name == baseName
        # Apache-2.0 4(b): the modified file carries a notice of the change
        && lib.hasPrefix "Modified by ai-sandbox from the nolabs-ai/claude ${vendoredVersion} profile (Apache-2.0)" base.meta.description
        && lib.hasInfix "modules/home-manager/vendor/README.md" base.meta.description;
      message = "bases: ai-sandbox-claude must be the vendored nolabs-ai/claude profile, changed only in extends, meta (its name and a modification notice), the ~/.claude grants, the config dir, the hook path and the environment";
    }
    {
      # P-noclaude: no profile of the claude pack grants anything of Claude Code's own config.
      condition = let
        fam = family on // family wider;
      in
        lib.all (n: fam ? ${n}) [baseName "claude-local" "claude-local-gpu" "claude-local-x" "svc-test"]
        && lib.all (p: !(lib.any claudeOwn (grants p))) (lib.attrValues fam);
      message = "bases: no profile of the claude pack (base, harness, GPU twin, variant, other harness) may grant ~/.claude, ~/.claude.json or anything below or beside them";
    }
    {
      # P-nopack: nor write nono's pack store or config, where the plugin dir and the session
      # hook live (claude-why asks the real nono for the plugin dir).
      condition = lib.all (p: !(lib.any nonoOwn (writes p))) (lib.attrValues (family on // family wider));
      message = "bases: no profile of the claude pack may write $NONO_PACKAGES or $NONO_CONFIG (but $NONO_CONFIG/profile-drafts), or a dir holding them";
    }
    {
      # P-dir: the config dir is the base's own, granted, set for the session and made by
      # activation; no leaf overrides it (the child's set_vars win).
      condition =
        base.environment.set_vars
        or {}
        == {
          CLAUDE_CONFIG_DIR = dir;
          CLAUDE_CODE_PLUGIN_DIRS = packDir;
        }
        && lib.elem dir base.filesystem.allow
        && lib.elem "/tmp/ai-test/.claude-sandbox" (dirsOf on)
        && lib.hasInfix "run install -d -m 0700 \"/tmp/ai-test/.claude-sandbox\"" (on.home.activation.aiSandboxDirs.data or "")
        && lib.all (p: !((p.environment.set_vars or {}) ? CLAUDE_CONFIG_DIR || (p.environment.set_vars or {}) ? CLAUDE_CODE_PLUGIN_DIRS)) (lib.attrValues (removeAttrs (family wider) [baseName]));
      message = "bases: ai-sandbox-claude must set CLAUDE_CONFIG_DIR to its granted $HOME/.claude-sandbox, which activation makes, and no leaf may override it";
    }
    {
      # P-dir-link: activation refuses a symlinked config dir before it writes anything (nono
      # would grant the link's target).
      condition = let
        e = on.home.activation.aiSandboxBaseDirs or {};
      in
        lib.hasInfix "if [ -L \"/tmp/ai-test/.claude-sandbox\" ]; then" (e.data or "")
        && lib.hasInfix "exit 1" (e.data or "")
        && e.before or [] == ["writeBoundary"];
      message = "bases: activation must refuse a ~/.claude-sandbox that is a symbolic link, before writeBoundary";
    }
    {
      # A base exists iff a profile of its pack does; it is reclaimed like every profile, and
      # it is a base only: no alias, no editor runtime dir, no editor grant.
      condition =
        on.programs.aiSandbox.internal.baseProfiles
        == aiBasePack
        && lib.hasInfix "/nono/profiles/${baseName}.json" (reclaim on)
        && !(lib.elem baseName on.programs.aiSandbox.internal.profileNames)
        && !(lib.any (a: lib.hasInfix "--profile ${baseName} " a) (lib.attrValues on.home.shellAliases))
        && (aiEmittedProfiles editor).${baseName} == base
        && !(lib.any (lib.hasSuffix "/run-${baseName}") (dirsOf editor))
        && (aiEmittedProfiles svcOnly).svc-test.extends == [baseName]
        && (aiEmittedProfiles svcOnly) ? ${baseName}
        && lib.elem "/tmp/ai-test/.claude-sandbox" (dirsOf svcOnly)
        && !((aiEmittedProfiles noClaude) ? ${baseName})
        && noClaude.programs.aiSandbox.internal.baseProfiles == {}
        && !(lib.any (lib.hasSuffix "/.claude-sandbox") (dirsOf noClaude))
        && !(lib.hasInfix baseName (reclaim noClaude))
        && aiEmittedProfiles off == {};
      message = "bases: ai-sandbox-claude is emitted (and reclaimed, its dir made) exactly while a profile of nolabs-ai/claude is, with no alias and no editor grants";
    }
  ]
