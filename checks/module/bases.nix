# The ai-sandbox bases (modules/home-manager/bases.nix) as the module emits them, over the
# standalone fixtures of ./lib.nix; wired by ./default.nix as ai-sandbox-bases. Each base is
# restated here, not read back from bases.nix: the vendored pack profile minus every grant on
# another harness's (or its own harness's) config, plus what the base adds.
{
  lib,
  helpers,
}: let
  inherit (helpers) mkAssertionCheck aiFixtureWith aiNoNvf aiEmittedProfiles aiBasePack;
  versionOf = pack: (import ../../modules/home-manager/bases.nix {inherit lib;}).${pack}.version;

  claudeDir = "$HOME/.claude-sandbox";
  # opencode's Claude Code config dir, inside its data dir (which the pack grants)
  ocDir = "$HOME/.local/share/opencode/claude";

  # base -> what it is made of and how (P-verbatim)
  specs = {
    ai-sandbox-claude = {
      pack = "nolabs-ai/claude";
      vendored = ../../modules/home-manager/vendor/nolabs-ai-claude.policy.json;
      dropAllow = ["$HOME/.claude"];
      addAllow = [claudeDir];
      dropFiles = ["$HOME/.claude.json" "$HOME/.claude.json.lock" "$HOME/.claude.lock"];
      setVars = {
        CLAUDE_CONFIG_DIR = claudeDir;
        CLAUDE_CODE_PLUGIN_DIRS = "$NONO_PACKAGES/nolabs-ai/claude";
      };
    };
    ai-sandbox-opencode = {
      pack = "nolabs-ai/opencode";
      vendored = ../../modules/home-manager/vendor/nolabs-ai-opencode.policy.json;
      dropAllow = ["$HOME/.claude" "$HOME/.codex"];
      addAllow = [];
      dropFiles = [];
      setVars = {CLAUDE_CONFIG_DIR = ocDir;};
    };
  };

  on = aiNoNvf.config;
  emitted = aiEmittedProfiles on;
  base = emitted.ai-sandbox-claude or {};
  ocBase = emitted.ai-sandbox-opencode or {};

  # a variant of each harness, a harness of another name on the claude pack (as a service is),
  # and the opencode-web service
  wider =
    (aiFixtureWith {
      programs.aiSandbox.variants.claude_x = {
        harness = "claude";
        suffix = "x";
        allow = ["$HOME/src/x"];
      };
      programs.aiSandbox.variants.opencode_x = {
        harness = "opencode";
        suffix = "x";
        allow = ["$HOME/src/x"];
      };
      programs.aiSandbox.harnesses.svc = {
        profileName = "svc-test";
        pack = "nolabs-ai/claude";
      };
      programs.aiSandbox.services.opencode-web.enable = true;
    })
    .config;
  noClaude = (aiFixtureWith {programs.aiSandbox.harnesses.claude.enable = false;}).config;
  noOpencode = (aiFixtureWith {programs.aiSandbox.harnesses.opencode.enable = false;}).config;
  svcOnly =
    (aiFixtureWith {
      programs.aiSandbox.harnesses.claude.enable = false;
      programs.aiSandbox.harnesses.svc = {
        profileName = "svc-test";
        pack = "nolabs-ai/claude";
      };
    })
    .config;
  # the opencode harness off, its web service on: the service alone needs the base
  ocSvcOnly =
    (aiFixtureWith {
      programs.aiSandbox.harnesses.opencode.enable = false;
      programs.aiSandbox.services.opencode-web.enable = true;
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
  # `${HOME}` spelled `$HOME`, no trailing slash
  norm = g: lib.removeSuffix "/" (builtins.replaceStrings ["\${HOME}"] ["$HOME"] g);
  # g is d, below d, or holds it (the home itself, or `/`)
  reaches = d: g0: let
    g = norm g0;
  in
    g == "" || g == "$HOME" || g == d || lib.hasPrefix "${d}/" g;
  # Claude Code's own config: the directory and `.claude.json` (+ locks); `$HOME/.claude-sandbox` is not.
  claudeOwn = g: reaches "$HOME/.claude" g || lib.hasPrefix "$HOME/.claude." (norm g);
  # Codex's own config
  codexOwn = reaches "$HOME/.codex";
  # the sandboxed Claude Code's config dir, another family's
  claudeSandboxOwn = reaches claudeDir;

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

  # The profiles of a base's pack in a home: the base and every profile extending it.
  familyOf = b: h: lib.filterAttrs (n: p: n == b || (p.extends or null) == [b]) (aiEmittedProfiles h);
  family = familyOf "ai-sandbox-claude";
  ocFamily = familyOf "ai-sandbox-opencode";

  dirsOf = h: h.programs.aiSandbox.internal.activationDirs;
  reclaim = h: h.home.activation.nonoProfileReclaim.data or "";
  kept = ["extends" "meta" "filesystem" "session_hooks" "environment"];
  setVarsOf = p: p.environment.set_vars or {};

  # P-verbatim of one base: outside the named keys it is the vendored pack profile; inside
  # them, exactly the stated transform.
  verbatim = name: s: let
    b = emitted.${name} or {};
    v = lib.importJSON s.vendored;
    packDir = "$NONO_PACKAGES/${s.pack}";
  in {
    condition =
      emitted ? ${name}
      && removeAttrs b kept == removeAttrs v kept
      && removeAttrs b.filesystem ["allow" "allow_file"] == removeAttrs v.filesystem ["allow" "allow_file"]
      && b.filesystem.allow == lib.subtractLists s.dropAllow v.filesystem.allow ++ s.addAllow
      && (b.filesystem ? allow_file) == (v.filesystem ? allow_file)
      && (b.filesystem.allow_file or []) == lib.subtractLists s.dropFiles (v.filesystem.allow_file or [])
      && b.session_hooks == lib.recursiveUpdate v.session_hooks {before.script = packDir + lib.removePrefix "$PACK_DIR" v.session_hooks.before.script;}
      && (b.environment or null)
      == (
        if s.setVars == {}
        then null
        else {set_vars = s.setVars;}
      )
      && b.extends == ["default"]
      && lib.attrNames b.meta == ["description" "name"]
      && b.meta.name == name
      # Apache-2.0 4(b): the modified file carries a notice of the change
      && lib.hasPrefix "Modified by ai-sandbox from the ${s.pack} ${versionOf s.pack} profile (Apache-2.0)" b.meta.description
      && lib.hasInfix "modules/home-manager/vendor/README.md" b.meta.description;
    message = "bases: ${name} must be the vendored ${s.pack} profile, changed only in extends, meta (its name and a modification notice), the dropped grants (${toString (s.dropAllow ++ s.dropFiles)}), the added ones, the hook path and the environment";
  };
in
  mkAssertionCheck "ai-sandbox-bases" ([
      {
        # Every base of bases.nix is restated above (the restatement is what the rows test).
        condition = lib.attrNames specs == lib.attrNames aiBasePack && lib.mapAttrs (_: s: s.pack) specs == aiBasePack;
        message = "bases: every ai-sandbox base (checks/module/lib.nix aiBasePack) needs its restated spec here";
      }
    ]
    ++ lib.mapAttrsToList verbatim specs
    ++ [
      {
        # P-noclaude: no profile of the claude pack grants anything of Claude Code's own config.
        condition = let
          fam = family on // family wider;
        in
          lib.all (n: fam ? ${n}) ["ai-sandbox-claude" "claude-local" "claude-local-gpu" "claude-local-x" "svc-test"]
          && lib.all (p: !(lib.any claudeOwn (grants p))) (lib.attrValues fam);
        message = "bases: no profile of the claude pack (base, harness, GPU twin, variant, other harness) may grant ~/.claude, ~/.claude.json or anything below or beside them";
      }
      {
        # P-noclaude-oc: nor any profile of the opencode pack, which reaches Claude through a
        # config dir of its own; and not the sandboxed Claude Code's dir either.
        condition = let
          fam = ocFamily on // ocFamily wider // ocFamily ocSvcOnly;
        in
          lib.all (n: fam ? ${n}) ["ai-sandbox-opencode" "opencode-claude" "opencode-claude-gpu" "opencode-claude-x" "opencode-web"]
          && lib.all (p: !(lib.any (g: claudeOwn g || claudeSandboxOwn g) (grants p))) (lib.attrValues fam);
        message = "bases: no profile of the opencode pack (base, harness, GPU twin, variant, service) may grant ~/.claude, ~/.claude.json, ~/.claude-sandbox or anything below or beside them";
      }
      {
        # P-nocodex: nor Codex's config.
        condition = lib.all (p: !(lib.any codexOwn (grants p))) (lib.attrValues (ocFamily on // ocFamily wider));
        message = "bases: no profile of the opencode pack may grant ~/.codex or anything below it";
      }
      {
        # P-nopack: nor write nono's pack store or config, where the plugin dir and the session
        # hook live (claude-why and opencode-why ask the real nono).
        condition = lib.all (p: !(lib.any nonoOwn (writes p))) (lib.attrValues (family on // family wider // ocFamily on // ocFamily wider));
        message = "bases: no profile of the claude or the opencode pack may write $NONO_PACKAGES or $NONO_CONFIG (but $NONO_CONFIG/profile-drafts), or a dir holding them";
      }
      {
        # P-dir: the config dir is the base's own, granted, set for the session and made by
        # activation; no leaf overrides it (the child's set_vars win).
        condition =
          setVarsOf base
          == specs.ai-sandbox-claude.setVars
          && lib.elem claudeDir base.filesystem.allow
          && lib.elem "/tmp/ai-test/.claude-sandbox" (dirsOf on)
          && lib.hasInfix "run install -d -m 0700 \"/tmp/ai-test/.claude-sandbox\"" (on.home.activation.aiSandboxDirs.data or "")
          && lib.all (p: !(setVarsOf p ? CLAUDE_CONFIG_DIR || setVarsOf p ? CLAUDE_CODE_PLUGIN_DIRS)) (lib.attrValues (removeAttrs (family wider) ["ai-sandbox-claude"]));
        message = "bases: ai-sandbox-claude must set CLAUDE_CONFIG_DIR to its granted $HOME/.claude-sandbox, which activation makes, and no leaf may override it";
      }
      {
        # P-dir-oc: opencode's Claude Code config dir is set by the base, lies inside a dir the
        # base grants rw, is made by activation, and no leaf (harness, twin, variant,
        # service) overrides it.
        condition =
          setVarsOf ocBase
          == {CLAUDE_CONFIG_DIR = ocDir;}
          && lib.any (a: lib.isString a && (a == ocDir || lib.hasPrefix "${a}/" ocDir)) (ocBase.filesystem.allow or [])
          && lib.elem "/tmp/ai-test/.local/share/opencode/claude" (dirsOf on)
          && lib.hasInfix "run install -d -m 0700 \"/tmp/ai-test/.local/share/opencode/claude\"" (on.home.activation.aiSandboxDirs.data or "")
          && lib.all (p: !(setVarsOf p ? CLAUDE_CONFIG_DIR)) (lib.attrValues (removeAttrs (ocFamily wider) ["ai-sandbox-opencode"]));
        message = "bases: ai-sandbox-opencode must set CLAUDE_CONFIG_DIR to $HOME/.local/share/opencode/claude, inside a dir it grants, which activation makes, and no leaf may override it";
      }
      {
        # P-dir-link: activation refuses a symlinked base dir before it writes anything (nono
        # would grant the link's target).
        condition = let
          e = on.home.activation.aiSandboxBaseDirs or {};
        in
          lib.all (d: lib.hasInfix "if [ -L \"${d}\" ]; then" (e.data or "")) ["/tmp/ai-test/.claude-sandbox" "/tmp/ai-test/.local/share/opencode/claude"]
          && lib.hasInfix "exit 1" (e.data or "")
          && e.before or [] == ["writeBoundary"];
        message = "bases: activation must refuse a base dir (~/.claude-sandbox, ~/.local/share/opencode/claude) that is a symbolic link, before writeBoundary";
      }
      {
        # A base exists iff a profile of its pack does; it is reclaimed like every profile, and
        # it is a base only: no alias, no editor runtime dir, no editor grant.
        condition =
          on.programs.aiSandbox.internal.baseProfiles
          == aiBasePack
          && lib.all (b: lib.hasInfix "/nono/profiles/${b}.json" (reclaim on)) (lib.attrNames aiBasePack)
          && lib.all (b: !(lib.elem b on.programs.aiSandbox.internal.profileNames)) (lib.attrNames aiBasePack)
          && !(lib.any (a: lib.any (b: lib.hasInfix "--profile ${b} " a) (lib.attrNames aiBasePack)) (lib.attrValues on.home.shellAliases))
          && (aiEmittedProfiles editor).ai-sandbox-claude == base
          && (aiEmittedProfiles editor).ai-sandbox-opencode == ocBase
          && !(lib.any (d: lib.hasSuffix "/run-ai-sandbox-claude" d || lib.hasSuffix "/run-ai-sandbox-opencode" d) (dirsOf editor))
          && aiEmittedProfiles off == {};
        message = "bases: the ai-sandbox bases are emitted and reclaimed with their packs' profiles, with no alias and no editor grants";
      }
      {
        condition =
          (aiEmittedProfiles svcOnly).svc-test.extends
          == ["ai-sandbox-claude"]
          && (aiEmittedProfiles svcOnly) ? ai-sandbox-claude
          && lib.elem "/tmp/ai-test/.claude-sandbox" (dirsOf svcOnly)
          && !((aiEmittedProfiles noClaude) ? ai-sandbox-claude)
          && !(noClaude.programs.aiSandbox.internal.baseProfiles ? ai-sandbox-claude)
          && !(lib.any (lib.hasSuffix "/.claude-sandbox") (dirsOf noClaude))
          && !(lib.hasInfix "ai-sandbox-claude" (reclaim noClaude));
        message = "bases: ai-sandbox-claude is emitted (and reclaimed, its dir made) exactly while a profile of nolabs-ai/claude is";
      }
      {
        condition =
          (aiEmittedProfiles ocSvcOnly).opencode-web.extends
          == ["ai-sandbox-opencode"]
          && (aiEmittedProfiles ocSvcOnly) ? ai-sandbox-opencode
          && !((aiEmittedProfiles ocSvcOnly) ? opencode-claude)
          && lib.elem "/tmp/ai-test/.local/share/opencode/claude" (dirsOf ocSvcOnly)
          && !((aiEmittedProfiles noOpencode) ? ai-sandbox-opencode)
          && noOpencode.programs.aiSandbox.internal.baseProfiles == {ai-sandbox-claude = "nolabs-ai/claude";}
          && !(lib.any (lib.hasSuffix "/.local/share/opencode/claude") (dirsOf noOpencode))
          && !(lib.hasInfix "ai-sandbox-opencode" (reclaim noOpencode));
        message = "bases: ai-sandbox-opencode is emitted (and reclaimed, its dir made) exactly while a profile of nolabs-ai/opencode is, the opencode-web service alone included";
      }
    ])
