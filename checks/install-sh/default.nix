# The installer without Nix, run in the build sandbox against stub tools (see
# cases.sh). The installer sees a PATH of stubs, bash, coreutils and the tools
# of scripts/deps only; `nix` and `sudo` stubs record any call.
{
  pkgs,
  lib,
  self,
  render,
}: let
  # The aliases the module defines, for the read-back cases: the alias -> value
  # set of F_S (ISOLATION=1) and F_S0 (ISOLATION=0), the harness each alias
  # belongs to, the aliases of GPU variants and the session variables.
  p = render.fs.programs.aiSandbox;
  twins = n: owner: [(lib.nameValuePair n owner) (lib.nameValuePair "${n}_nono" owner)];
  aliasesJson = pkgs.writeText "aliases.json" (builtins.toJSON {
    values = {
      "1" = render.fs.home.shellAliases;
      "0" = render.fs0.home.shellAliases;
    };
    harness =
      lib.listToAttrs (lib.concatMap (h: twins h h) (lib.attrNames p.harnessProfiles)
        ++ lib.concatLists (lib.mapAttrsToList (alias: e: twins alias e.command) p.internal.variants));
    gpu = lib.concatLists (lib.mapAttrsToList (alias: e: lib.optionals e.spec.allowGpu [alias "${alias}_nono"]) p.internal.variants);
    session.NONO_AUTO_MIGRATE = toString render.fs.home.sessionVariables.NONO_AUTO_MIGRATE;
  });
in
  pkgs.runCommand "install-sh" {
    nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.findutils pkgs.diffutils];
    BASH_BIN = "${pkgs.bash}/bin";
    BASE = lib.makeBinPath [pkgs.bash pkgs.coreutils];
    JQ_BIN = lib.makeBinPath [pkgs.jq];
    GIT_BIN = lib.makeBinPath [pkgs.git];
    SOCAT_BIN = lib.makeBinPath [pkgs.socat];
    UL_BIN = lib.makeBinPath [pkgs.util-linux];
    ZSH_BIN = lib.makeBinPath [pkgs.zsh];
    # a read-only directory with the command the opencode-web unit runs (SERVICE_PATH)
    OPENCODE_BIN = lib.makeBinPath [(pkgs.writeShellScriptBin "opencode" "exit 0")];
    ALIASES_JSON = aliasesJson;
    # the module's service files for other proxy.listenAddress values (LABEL=ADDRESS ...)
    LISTEN_TREE = render.listenTree;
    LISTEN_ADDRS = toString (lib.mapAttrsToList (l: a: "${l}=${a}") render.listenAddresses);
  } ''
    cp -r ${self} repo
    chmod -R u+w repo
    # the build sandbox has no /usr/bin/env (only executables are patched)
    patchShebangs repo >/dev/null
    export REPO=$PWD/repo
    bash ${./cases.sh}
    touch $out
  ''
