# The variables the Nix build injects into the wrapper (sandbox-run.nix),
# assigned from install-time values by scripts/install.sh: every value between
# two at-signs is replaced by a shell-quoted value. One assignment per line; the
# check preamble-vars compares the names with the Nix preamble.
all_layers=(@all_layers@)
default_layers=(@default_layers@)
docker_sockets=(@docker_sockets@)
system_sockets=(@system_sockets@)
runtime_root=@runtime_root@
shim_bin=@libexec@/shim
url_relay=@libexec@/ai-sandbox-url-relay
bwrap=@bwrap@
socat=@socat@
jq=@jq@
git=@git@
nono_bin=@nono@
coreutils=@coreutils@
