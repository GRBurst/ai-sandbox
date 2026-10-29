# NixOS side of the AI sandbox (this repository's `nixosModules.default`): the kernel
# setting the wrapper relies on. The Home Manager module is separate (modules/home-manager/);
# both carry the public option name `programs.aiSandbox`.
{
  config,
  lib,
  ...
}: {
  key = "ai-sandbox#ai-sandbox-nixos";

  options.programs.aiSandbox.enable = lib.mkEnableOption "the kernel settings the AI sandbox relies on (TIOCSTI injection off)";

  config = lib.mkIf config.programs.aiSandbox.enable {
    # TIOCSTI injection into the parent terminal stays impossible; the sandbox wrapper
    # relies on this instead of bwrap --new-session, which would break job control.
    # Pinned to the kernel default.
    boot.kernel.sysctl."dev.tty.legacy_tiocsti" = 0;
  };
}
