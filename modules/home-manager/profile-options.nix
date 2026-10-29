# The options of one profile (the grant fields plus its pack and groups), shared by the harnesses
# and the services' inline `profile`: a profile field added here reaches both.
{lib}:
import ./grants.nix {inherit lib;}
// {
  pack = lib.mkOption {
    type = lib.types.str;
    description = "The nono registry pack the profile extends: its single `extends` entry.";
  };
  include = lib.mkOption {
    type = with lib.types; listOf str;
    default = [];
    description = "groups.include for packs whose own group list is incomplete on NixOS.";
  };
  exclude = lib.mkOption {
    type = with lib.types; listOf str;
    default = [];
    description = "groups.exclude: inherited groups unrelated to what the agent needs.";
  };
  denyVars = lib.mkOption {
    type = with lib.types; listOf str;
    default = ["WAYLAND_DISPLAY" "DISPLAY"];
    description = "Variables stripped so the harness copies through the terminal (OSC 52).";
  };
  readsSharedSkills = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "The harness scans the shared skills dir and its pack does not grant it: add a read grant.";
  };
}
