# The grant fields shared by harnesses, packDefaults, variants and the services' profiles (through
# profile-options.nix): one place for the option shapes, so a grant added here reaches every consumer.
{lib}:
with lib.types; {
  allow = lib.mkOption {
    type = listOf str;
    default = [];
    description = "Read+write paths.";
  };
  allowFile = lib.mkOption {
    type = listOf str;
    default = [];
    description = "Read+write single files.";
  };
  read = lib.mkOption {
    type = listOf str;
    default = [];
    description = "Read-only paths.";
  };
  readFile = lib.mkOption {
    type = listOf str;
    default = [];
    description = "Read-only single files.";
  };
  deny = lib.mkOption {
    type = listOf str;
    default = [];
    description = "Paths denied on top of `profileDefaults.deny`.";
  };
  setVars = lib.mkOption {
    type = attrsOf str;
    default = {};
    description = "Environment variables set inside the sandbox (nono expands $XDG_* and $HOME).";
  };
  unixSocketSubtreeBind = lib.mkOption {
    type = listOf str;
    default = [];
    description = "Extra connect+bind socket subtrees under unix mediation.";
  };
}
