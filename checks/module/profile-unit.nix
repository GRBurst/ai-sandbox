# Unit rows of the pure profile emitter (modules/home-manager/profile.nix): synthetic
# arguments, no home-manager evaluation. Wired by ./default.nix as ai-sandbox-profile-unit.
{
  lib,
  helpers,
}: let
  inherit (helpers) mkAssertionCheck;
  emit = import (helpers.module + "/profile.nix") {inherit lib;};
  base = {
    name = "t";
    pack = "p/t";
    deny = ["$HOME/.d"];
  };
  plain = emit base;
  editorOn = emit (base
    // {
      editor = {readFile = ["$XDG_STATE_HOME/mode"];};
      readFile = ["$HOME/r"];
    });
  mediated = emit (base // {mediation = true;});
  mediatedEditor = emit (base
    // {
      mediation = true;
      editor = {};
    });
  hasUnixSocket = p: lib.any (lib.hasPrefix "unix_socket") (lib.attrNames p.filesystem);
in
  mkAssertionCheck "ai-sandbox-profile-unit" [
    {
      condition = plain.extends == ["p/t"];
      message = "profile-unit: exactly one extends entry, the pack";
    }
    {
      condition = !(plain ? interactive) && !(editorOn ? interactive);
      message = "profile-unit: no `interactive` key (nono 0.78 rejects it)";
    }
    {
      condition = plain.filesystem.deny == ["$HOME/.d"] && (emit (base // {deny = [];})).filesystem ? deny;
      message = "profile-unit: filesystem.deny is emitted from the argument, also when empty";
    }
    {
      condition =
        plain
        == {
          "$schema" = "https://nono.sh/schemas/nono-profile.schema.json";
          extends = ["p/t"];
          meta.name = "t";
          groups.exclude = [];
          filesystem = {
            allow = [];
            allow_file = [];
            deny = ["$HOME/.d"];
          };
        };
      message = "profile-unit: the minimal profile is exactly the pinned literal (no optional key leaks in)";
    }
    {
      condition = !(plain ? allow_gpu) && (emit (base // {allowGpu = true;})).allow_gpu == true;
      message = "profile-unit: allow_gpu only with allowGpu";
    }
    {
      condition = !(plain ? network) && (emit (base // {listenPorts = [1234];})).network.listen_port == [1234];
      message = "profile-unit: network.listen_port only when ports are given";
    }
    {
      condition = !(plain.groups ? include) && (emit (base // {include = ["g"];})).groups.include == ["g"];
      message = "profile-unit: groups.include only when non-empty";
    }
    {
      condition = !(plain ? linux) && !(hasUnixSocket plain) && !(editorOn ? linux) && !(plain ? environment);
      message = "profile-unit: no mediation keys and no environment without mediation/editor/cache pins";
    }
    {
      condition =
        editorOn.filesystem.allow
        == ["$XDG_STATE_HOME/nvf" "$XDG_CACHE_HOME/nvf"]
        && editorOn.environment.set_vars.XDG_RUNTIME_DIR == "$XDG_STATE_HOME/nvf/run-t"
        && editorOn.filesystem.read_file == ["$XDG_STATE_HOME/mode" "$HOME/r"];
      message = "profile-unit: the editor grants, the per-profile runtime dir and the editor's read file (before the profile's own) appear with editor";
    }
    {
      condition =
        mediated.linux.af_unix_mediation
        == "pathname"
        && mediated.filesystem.unix_socket == ["/nix/var/nix/daemon-socket/socket" "/run/nscd/socket"]
        && mediated.filesystem.unix_socket_subtree_bind == ["$TMPDIR"]
        && mediatedEditor.filesystem.unix_socket_subtree_bind == ["$TMPDIR" "$XDG_STATE_HOME/nvf/run-t"];
      message = "profile-unit: mediation emits the socket grant set, plus the editor runtime dir with editor";
    }
    {
      condition =
        (emit (base
          // {
            setVars = {A = "1";};
            denyVars = ["X"];
          })).environment
        == {
          set_vars = {A = "1";};
          deny_vars = ["X"];
        };
      message = "profile-unit: set_vars and deny_vars pass through";
    }
  ]
