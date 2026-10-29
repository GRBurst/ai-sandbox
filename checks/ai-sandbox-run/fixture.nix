# What the wrapper suites share: the fixture directory `fx`, the stub tools and
# the runtime root and socket lists the wrappers under test are built with (the
# Nix-built ones through sandbox-run.nix, the installed ones through a
# defaults file).
{
  writeShellScript,
  writeShellScriptBin,
}: let
  fx = "/tmp/ai-sandbox-fixture";
  openText = ''
    printf '%s\n' "$1" >> ${fx}/opened
  '';
in {
  inherit fx;
  fakeNono = writeShellScriptBin "nono" ''
    printf '%s\n' '{"open_urls":{"allow_origins":["https://github.com"],"allow_localhost":true}}'
  '';
  # the opener the relay runs: records the URL it was asked to open
  fakeOpen = writeShellScript "fake-xdg-open" openText;
  fakeOpenBin = writeShellScriptBin "xdg-open" openText;
  runtimeRoot = "${fx}/run/user";
  sockets = {
    docker = ["${fx}/docker.sock" "${fx}/absent.sock"];
    system = ["${fx}/system_bus_socket"];
  };
}
