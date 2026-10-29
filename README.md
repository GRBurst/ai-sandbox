# ai-sandbox

Sandbox for AI coding agents: nono profiles and harness wrappers, with an
isolation layer (bubblewrap) around each agent. Public, MIT licensed (see
`LICENSE`).

The repository works without Nix (`scripts/install.sh install`,
`shell/variant.sh`; see "Without Nix"), and it has first-class Nix support: the
Home Manager and NixOS modules are the source of every generated file.

Status: complete for the first release. The Home Manager and NixOS modules are
the source; the nono profiles, aliases, units and the sysctl file for use without Nix are generated
from them (`profiles/`, `shell/`, `sysctl/`, `services/`, `services-nono/`,
`install/`).

## Outputs

- `homeModules.default`: Home Manager module, key `ai-sandbox#ai-sandbox`.
- `nixosModules.default`: NixOS module, key `ai-sandbox#ai-sandbox-nixos`.
- `packages.<system>.ai-sandbox-run`: the isolation wrapper (bubblewrap around nono).
- `checks.<system>`: `formatting`, `leaks`, `readme-options`, `readme-sections`, `ai-sandbox-run`,
  `shellcheck`, `actionlint`, `run-portable`, `install-sh`, `readme-deps`, `doc-refs`,
  `boundary`, `nixos-output`, `render-profiles`, `render-aliases`, `render-units`, `render-sysctl`, `render-install`, `variant-sh`, `extends-shape`, `existing-flake-example`;
  the module checks (`checks/module`) `fixtures`, `isolation`, `profiles`, `aliases`,
  `home`, `services`, `variants`, `harnesses`, `profile-unit`, `nixos`.
- `apps.<system>.render`: `nix run .#render` from the checkout writes the generated files for use
  without Nix (`profiles/`, `shell/aliases.d/`, ...) from this module; the `render-*` checks compare them with its output.
- `legacyPackages.<system>.render-tree`: that output as a store path.
- `formatter.<system>`: Alejandra.

The check list above is kept equal to the flake's checks by `readme-sections`.

The repository imports nothing from the other AI repositories. Its inputs
(`nixpkgs`, `home-manager`) exist for the checks; consumers `follows` their own.

## Install with Nix

Add the flake as an input and let it follow your `nixpkgs` and `home-manager`:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  home-manager = {
    url = "github:nix-community/home-manager";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  ai-sandbox = {
    url = "github:GRBurst/ai-sandbox";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.home-manager.follows = "home-manager";
  };
};
```

Import the Home Manager module and switch it on:

```nix
# a Home Manager module of your configuration
{inputs, pkgs, ...}: {
  imports = [inputs.ai-sandbox.homeModules.default];
  programs.aiSandbox.enable = true;
  # optional: install the CLI next to its profile (null, the default, installs nothing)
  programs.aiSandbox.harnesses.opencode.package = pkgs.opencode;
}
```

`inputs` is a module argument only when your flake passes it in:
`extraSpecialArgs = {inherit inputs;};` in `home-manager.lib.homeManagerConfiguration`
(standalone), `home-manager.extraSpecialArgs = {inherit inputs;};` in the NixOS
module of Home Manager, and `specialArgs = {inherit inputs;};` in
`nixpkgs.lib.nixosSystem` for the NixOS module below. Without it the module fails
with "attribute 'inputs' missing". `examples/existing-flake/` avoids it: it
lists `ai-sandbox.homeModules.default` in `modules` straight from the `outputs`
arguments.

What `enable = true` gives you, with every default:

- The four harness presets are **on**: `agy`, `claude`, `opencode` and `pi`.
  Each gets a nono profile and an alias of its own name (`agy`, `claude`,
  `opencode`, `pi`) that runs the command through the isolation and nono, and
  a `_nono` twin (`claude_nono`, ...) that runs it through nono only.
  Switch one off with `programs.aiSandbox.harnesses.<name>.enable = false`.
- GPU twins `claude_gpu` and `opencode_gpu` (and their `_nono` twins), with
  their own `-gpu` profiles; the plain aliases stay without GPU access.
  `programs.aiSandbox.gpu.enable = false` drops them.
- The service preset `opencode-web` exists but is **off**: set
  `programs.aiSandbox.services.opencode-web.enable = true` to run the opencode
  web UI as sandboxed systemd user units behind a compressing proxy that
  listens on `127.0.0.1` only (`proxy.listenAddress`; see "Ports").
  The units' `PATH` (`services.<name>.path`) defaults to the NixOS user
  `PATH` without your writable directories: `/run/wrappers/bin`,
  `/etc/profiles/per-user/<user>/bin` and `/run/current-system/sw/bin`.
  `opencode` is found there only on NixOS with
  `home-manager.useUserPackages = true`. Outside NixOS, or without
  `useUserPackages`, Home Manager puts it in `~/.nix-profile/bin`, the unit
  does not find it and restarts every 5 seconds: set the `PATH` to directories
  the sandbox cannot write that hold what the agent runs, for example store
  paths (read-only, owned by root):
  `programs.aiSandbox.services.opencode-web.path = ["${pkgs.opencode}/bin" "${pkgs.git}/bin" "${pkgs.coreutils}/bin" "/usr/bin" "/bin"];`.
  `--strict-broker-path` refuses a `PATH` entry the sandbox can write;
  `~/.nix-profile/bin` is reached through links you own, so prefer store paths.
- nono installs the registry packs the profiles extend on the first run,
  without prompting (`autoInstallPacks`); that needs network access once.

A project-directory variant is a harness profile with one more grant, with its
own aliases:

```nix
programs.aiSandbox.variants.pi_notes = {
  harness = "pi";
  suffix = "notes";
  allow = ["$HOME/src/notes"];
};
```

This gives the profile `pi-claude-notes` and the aliases `pi_notes` and
`pi_notes_nono`.

`examples/existing-flake/` is this as a complete flake (an existing Home Manager
flake with the module added); the check `existing-flake-example` evaluates it.

The NixOS module `nixosModules.default` is separate and has its own
`programs.aiSandbox.enable`: it sets the kernel setting `dev.tty.legacy_tiocsti = 0`
(no TIOCSTI injection into the parent terminal), which the isolation relies on.
Import it in your NixOS configuration (`imports = [inputs.ai-sandbox.nixosModules.default];`
and `programs.aiSandbox.enable = true;`) next to the Home Manager module, which
you use as a Home Manager module of your users, standalone or through the NixOS
module of Home Manager. The two modules share only the option name; each
declares what it needs. With Home Manager outside NixOS there is no NixOS
module: set the kernel setting yourself, with the line "Without Nix" prints
(`printf '%s\n' 'dev.tty.legacy_tiocsti = 0' | sudo tee
/etc/sysctl.d/60-ai-sandbox.conf >/dev/null`, then `sudo sysctl --system`).

## Without Nix

Nix is not needed. Clone the repository
(`git clone https://github.com/GRBurst/ai-sandbox`) and run `scripts/install.sh
install`; `scripts/install.sh uninstall` removes what it wrote. Without Nix the
sandbox needs Linux with Landlock and unprivileged user namespaces, bash or
zsh, and only these tools. `scripts/deps` lists them and the check
`readme-deps` keeps the table and that file equal.

| binary | package | needed when | minimum |
| --- | --- | --- | --- |
| `bash` | `bash` | always | 4.4 |
| `jq` | `jq` | always | - |
| `nono` | `nono` | always | see `profiles/NONO_VERSION` |
| `install` | `coreutils` | always | GNU |
| `sha256sum` | `coreutils` | always | GNU |
| `bwrap` | `bubblewrap` | isolation | - |
| `socat` | `socat` | isolation | - |
| `git` | `git` | isolation | - |
| `setsid` | `util-linux` | isolation | - |
| `caddy` | `caddy` | services | - |
| `xdg-open` | `xdg-utils` | optional | - |

The harness CLIs themselves (`claude`, `opencode`, `pi`, `agy`) are not
installed: install those you select with `HARNESSES` yourself, on your `PATH`;
the aliases run them by name. The services need a systemd user session
(`systemctl --user`).

Install:

```sh
scripts/install.sh install                                   # defaults
HARNESSES=claude,pi GPU=0 scripts/install.sh install         # fewer harnesses, no GPU variants
SERVICES=opencode-web scripts/install.sh install             # also the opencode web UI units
```

Options (environment variables of `scripts/install.sh install`):

- `PREFIX` (default `~/.local`): the wrapper goes to `$PREFIX/bin/ai-sandbox-run`,
  the shell files to `$PREFIX/share/ai-sandbox/shell/`.
- `HARNESSES` (default `claude,opencode,pi,agy`): the harnesses whose profiles
  and aliases are installed; an unknown name is refused.
- `GPU` (default `1`): `0` leaves out the GPU variants (`claude_gpu`, `opencode_gpu`).
- `ISOLATION` (default `1`): `0` installs no wrapper and the `shell/aliases-nono.d/`
  aliases, which run nono only (and `services-nono/` units for services).
- `SERVICES` (default none): comma- or blank-separated web-UI services to install as
  systemd user units, for example `opencode-web`. Their working tree
  (`$HOME/projects`) must exist.
- `SERVICE_PATH` (default `/usr/local/bin:/usr/bin:/bin`): the `PATH` of the service
  units. The unit runs `opencode` with nono's `--strict-broker-path`, which
  refuses a `PATH` directory that a filesystem grant of the sandbox covers or
  that the user can write to. The installer refuses, and names the entry, when
  an entry is missing, writable by you, owned by you (you could make it
  writable again), inside the service's working tree or inside a read-write
  grant of its profile (a layer's, when one installs it; not the profiles it
  extends), or when the command is not found on it, instead of
  installing a unit that never starts. So `~/.local/bin`, an npm prefix of
  yours or a directory under `$HOME/projects` does not work: install the
  command in a directory only root can write, or point `SERVICE_PATH` at such
  directories.
- `PROXY_LISTEN` (default `127.0.0.1`): the address the services' proxies bind,
  as `proxy.listenAddress` with Nix. The default serves this machine only;
  `0.0.0.0` binds every interface (see "Ports"). Anything but an IPv4 or IPv6
  address (no brackets, zone or port) is refused.
- `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_CACHE_HOME` are honoured: the nono
  profiles go to `$XDG_CONFIG_HOME/nono/profiles/`, the units to
  `$XDG_CONFIG_HOME/systemd/user/`, the manifest to `$XDG_DATA_HOME/ai-sandbox/`,
  and the per-command cache directories (made `0700`) under `$XDG_CACHE_HOME`.
  All of them, and `PREFIX`, must be absolute paths of letters, digits and
  `. _ + @ -` only.

The installer records `HARNESSES`, `GPU`, `ISOLATION`, `SERVICES`,
`SERVICE_PATH` and `PROXY_LISTEN` when you set them
(`$XDG_DATA_HOME/ai-sandbox/options`, one `NAME=VALUE` line each, removed by
`scripts/install.sh uninstall`). A later run reuses the recorded value of an option you leave
empty or unset, and prints the ones it reused, so a plain `scripts/install.sh install`
repeats the last install. Set an option to change it, or to `default` to take
the default and drop it from the record (`SERVICES=default` removes the
services). `PREFIX` and the XDG directories are not recorded: give them again
(a run with another `PREFIX` or `XDG_CONFIG_HOME` refuses the manifest of the
old one).

The installer never edits a shell rc file and never runs `sudo`, `systemctl` or
`nix`. It checks everything before it writes the first file, so a refusal (a
missing tool, a file that is not yours, a file or a directory you cannot write
where a directory must go, a bad `SERVICE_PATH`, a value that looks like a
placeholder, `@NAME@`) leaves nothing half installed; a failure it cannot
foresee (a full disk) keeps a partial manifest, so `scripts/install.sh uninstall` still finds
what was written. It prints what is left to you:

- the line to add to `~/.bashrc` or `~/.zshrc`:
  `. $PREFIX/share/ai-sandbox/shell/aliases.sh`;
- with `ISOLATION=1` and `$PREFIX/bin` not on your `PATH`, a hint to add it
  (the aliases run `ai-sandbox-run` from there);
- with `SERVICES`, `systemctl --user daemon-reload` and
  `systemctl --user enable --now <units>`, and the address and port the proxy
  then listens on (`PROXY_LISTEN`; off loopback, with a reminder to keep the
  port closed in your firewall).
  On a reinstall that changed a unit, or the Caddyfile, profile or wrapper it
  uses, also `systemctl --user try-restart
  <units>`: a running unit keeps its old state until it restarts;
- the kernel setting the NixOS module makes, as a line that writes the pinned
  setting itself, so root does not copy a file out of your checkout:
  `printf '%s\n' 'dev.tty.legacy_tiocsti = 0' | sudo tee
  /etc/sysctl.d/60-ai-sandbox.conf >/dev/null`, then `sudo sysctl --system`
  (the installer refuses a `sysctl/60-ai-sandbox.conf` that holds anything
  else).

Files that exist, are not in the manifest and differ are never overwritten (the
install stops and names them); `scripts/install.sh uninstall` removes exactly the files of
the manifest and leaves directories it created. It refuses, and tells you to
run `systemctl --user disable --now <units>` first, while a service unit it
would remove is enabled (an uninstall, or a reinstall that leaves its service
out, such as `SERVICES=default`; the message then names the `SERVICES` value
that keeps it): removing the file of a running service would leave it running
unseen. Enabled means a link of `systemctl --user enable` under the unit
directory, or of `enable --runtime` under `$XDG_RUNTIME_DIR/systemd/user`. A
unit you started by hand shows nothing the installer can see: stop it yourself.

Layering without Nix: nono's `extends` only adds, so put a profile that extends
a shipped one in a directory of your own (see `examples/without-nix/`, whose
`pi-claude-notes.json` extends `pi-claude`), register the directory as a layer,
and define the alias with `variant.sh`:

```sh
scripts/install.sh install --layer notes=$HOME/ai-layers   # *.json of that directory, later layers win
. ~/.local/share/ai-sandbox/shell/variant.sh
ai_sandbox_variant pi_notes pi pi-claude-notes             # defines pi_notes and pi_notes_nono
```

Layers are recorded like the options, so a plain `scripts/install.sh install` reapplies them; to drop one,
delete its line from `$XDG_DATA_HOME/ai-sandbox/layers` (or uninstall, which
removes the record) and install again. `variant.sh`
(sourced by bash and zsh) builds exactly the alias strings the Nix module does;
put both lines in your rc file. The same
variant with Nix is `programs.aiSandbox.variants.pi_notes` (see above), which
flattens the chain to one `extends`. With `ISOLATION=0` there is no wrapper,
and `pi_notes` would run `ai-sandbox-run` and fail with "not found"; define the
nono-only alias instead:
`alias pi_notes="$(ai_sandbox_alias_string --nono-only pi pi-claude-notes)"`.

nono's registry packs are fetched at run time: `aliases.sh` exports
`NONO_AUTO_MIGRATE=1` so the first run installs them, or run
`nono pull nolabs-ai/claude` (likewise `opencode`, `pi`, `antigravity`) yourself.

What you do not get without Nix:

- No typed options and no assertions at evaluation: the installer preflights its
  inputs, `variant.sh` refuses a bad `TMPDIR` fallback, nothing else is validated.
- No render-time hooks (`editor.*`, `profileDefaults`, `packDefaults`): add
  grants with an `extends` profile. Removing a shipped grant is not possible
  (nono has no removal); copy the profile under a new name and own it.
- No activation: directories are made once at install; re-run `scripts/install.sh install`
  after a `git pull` (it reuses the recorded options and layers; that is also
  how profiles nono rewrote are restored).
- No generations or rollback: `scripts/install.sh uninstall` is the way back.
- Distribution versions of nono, bubblewrap, socat and caddy, with the minimums
  above, instead of a pinned closure.
- The sysctl file is installed by hand (see the printed lines).
- bash and zsh only (fish aliases need Home Manager).

## Options

All under `programs.aiSandbox`. The check `readme-options` keeps this table
and the option tree in step. A `—` in the Default column means the option is
required, no default: you or a preset must set it. The NixOS module
(`nixosModules.default`) has one option of its own, `programs.aiSandbox.enable`,
which sets the kernel setting `dev.tty.legacy_tiocsti = 0`; the table is
the Home Manager module's.

| Option | Default | Meaning |
| --- | --- | --- |
| `autoInstallPacks` | `true` | Set `NONO_AUTO_MIGRATE`, so nono installs missing registry packs without prompting on the first run. |
| `editor.appName` | `"nvf"` | The editor's `NVIM_APPNAME`; its XDG dirs are named after it. |
| `editor.enable` | `false` | Grant the editor to every profile: its state and cache dirs and a per-profile runtime dir. |
| `editor.readFile` | `[ ]` | Single files every profile may read while the editor grants are on (e.g. a theme mode file). |
| `enable` | `false` | Run AI agents through the nono sandbox. |
| `extraAliases` | `{ }` | Additional aliases; one overrides the generated alias of the same name (e.g. for extra `nono run` flags). |
| `gpu.args` | `[ "--allow-gpu" ]` | Extra `nono run` flags of the GPU aliases only; `--allow-gpu` belongs here, not in `nonoArgs`. |
| `gpu.display` | `true` | Also grant what a windowed GPU application needs (X11 cookie, POSIX shared memory); `false` for headless compute. X11 has no client isolation. |
| `gpu.enable` | `true` | Generate a GPU twin (`<profile>-gpu`) for each entry of `gpu.variants`, under its own alias; the default aliases stay without GPU. |
| `gpu.variants` | `claude_gpu`, `opencode_gpu` | GPU alias name mapped to the harness it shadows; the twin extends the base's pack, not the base profile. |
| `harnessProfiles` | read-only | The command of every enabled harness mapped to its profile name, also while the module is off; twins and variants not included. |
| `harnesses.<name>.allow` | `[ ]` | Read+write paths. |
| `harnesses.<name>.allowFile` | `[ ]` | Read+write single files. |
| `harnesses.<name>.deny` | `[ ]` | Paths denied on top of `profileDefaults.deny`. |
| `harnesses.<name>.denyVars` | `[ "WAYLAND_DISPLAY" "DISPLAY" ]` | Variables stripped, so the harness copies through the terminal (OSC 52). |
| `harnesses.<name>.enable` | `true` | Generate this harness's profile and aliases. |
| `harnesses.<name>.exclude` | `[ ]` | `groups.exclude`: inherited groups unrelated to what the agent needs. |
| `harnesses.<name>.include` | `[ ]` | `groups.include` for packs whose own group list is incomplete on NixOS. |
| `harnesses.<name>.pack` | — | The nono registry pack the profile extends (its single `extends` entry); the presets set it. |
| `harnesses.<name>.package` | `null` | The harness's CLI, installed while the harness and the module are on; must provide `bin/<name>`. `null` installs nothing. |
| `harnesses.<name>.profileName` | — | Name of the generated nono profile; the presets set it. |
| `harnesses.<name>.read` | `[ ]` | Read-only paths. |
| `harnesses.<name>.readFile` | `[ ]` | Read-only single files. |
| `harnesses.<name>.readsSharedSkills` | `false` | Add a read grant on `sharedSkillsDir` (the harness scans it and its pack does not grant it). |
| `harnesses.<name>.setVars` | `{ }` | Environment variables set inside the sandbox (nono expands `$XDG_*` and `$HOME`). |
| `harnesses.<name>.unixSocketSubtreeBind` | `[ ]` | Extra connect+bind socket subtrees under unix mediation. |
| `isolation.enable` | `true` | The namespace isolation around nono (`ai-sandbox-run`): hides the runtime dir, sockets, other processes and the host `/tmp`; read-only git hooks and config. Adds an `<alias>_nono` twin of every alias. |
| `isolation.layers` | all seven | The isolation layers on by default (`session`, `docker`, `system`, `pid`, `tmp`, `git`, `userns`); `AI_SANDBOX_RELAX` turns them off for one run. |
| `nonoArgs` | `[ "--allow-cwd" ]` | Extra `nono run` flags of every generated alias; path grants belong in the profile, not here. |
| `packDefaults.<name>.allow` | `[ ]` | Read+write paths of every profile that extends the pack `<name>`. |
| `packDefaults.<name>.allowFile` | `[ ]` | Read+write single files of every profile that extends the pack. |
| `packDefaults.<name>.deny` | `[ ]` | Paths denied on top of `profileDefaults.deny`. |
| `packDefaults.<name>.read` | `[ ]` | Read-only paths of every profile that extends the pack. |
| `packDefaults.<name>.readFile` | `[ ]` | Read-only single files of every profile that extends the pack. |
| `packDefaults.<name>.setVars` | `{ }` | Environment variables set inside the sandbox (nono expands `$XDG_*` and `$HOME`). |
| `packDefaults.<name>.unixSocketSubtreeBind` | `[ ]` | Extra connect+bind socket subtrees under unix mediation. |
| `package` | `pkgs.nono` | The nono sandbox CLI. |
| `profileDefaults.allow` | `[ ]` | Read+write paths every profile is granted. |
| `profileDefaults.deny` | `[ ]` | Paths every profile denies (Landlock cannot deny inside an allow). |
| `profileDefaults.read` | `[ ]` | Read-only paths every profile is granted. |
| `profileDefaults.readFile` | `[ ]` | Read-only single files every profile is granted. |
| `projectsDir` | `"$HOME/projects"` | The services' static work tree, spelled `$HOME`-relative as nono expands it. |
| `render.command` | read-only | Renders a sandboxed command line (`{command, profile, ...}`) to the string an alias holds; for helpers that run a harness in another harness's profile. |
| `runPackage` | read-only | The `ai-sandbox-run` wrapper built from `package` and `isolation.layers`; for modules that start a sandboxed command outside the aliases. |
| `serviceUnits` | read-only | Every enabled service mapped to the systemd user units it generates (with the proxy, `<name>-proxy`); for runtime verifiers. |
| `services.<name>.backendPort` | — | Loopback port the backend binds; the profile's only `network.listen_port`. |
| `services.<name>.backendUnit` | `"<name>"` | The unit that binds `backendPort`; the proxy is ordered against it. |
| `services.<name>.dataDirs` | `[ ]` | Absolute dirs created 0700 at activation (nono drops a grant whose path does not exist). |
| `services.<name>.enable` | `false` | Run the service: its sandboxed systemd user units and, with `proxy.enable`, the proxy. |
| `services.<name>.listenPort` | — | Port the proxy listens on, the one a browser connects to; never opened in a firewall by this module. |
| `services.<name>.path` | the NixOS user `PATH` | `PATH` of the sandboxed units; must contain nothing the sandbox can write. |
| `services.<name>.profile.allow` | `[ ]` | Read+write paths. |
| `services.<name>.profile.allowFile` | `[ ]` | Read+write single files. |
| `services.<name>.profile.deny` | `[ ]` | Paths denied on top of `profileDefaults.deny`. |
| `services.<name>.profile.denyVars` | `[ "WAYLAND_DISPLAY" "DISPLAY" ]` | Variables stripped, so the harness copies through the terminal (OSC 52). |
| `services.<name>.profile.exclude` | `[ ]` | `groups.exclude`: inherited groups unrelated to what the agent needs. |
| `services.<name>.profile.include` | `[ ]` | `groups.include` for packs whose own group list is incomplete on NixOS. |
| `services.<name>.profile.pack` | — | The nono registry pack the service's profile extends (its single `extends` entry). |
| `services.<name>.profile.read` | `[ ]` | Read-only paths. |
| `services.<name>.profile.readFile` | `[ ]` | Read-only single files. |
| `services.<name>.profile.readsSharedSkills` | `false` | Add a read grant on `sharedSkillsDir`. |
| `services.<name>.profile.setVars` | `{ }` | Environment variables set inside the sandbox (nono expands `$XDG_*` and `$HOME`). |
| `services.<name>.profile.unixSocketSubtreeBind` | `[ ]` | Extra connect+bind socket subtrees under unix mediation. |
| `services.<name>.proxy.enable` | `true` | Front the backend with a compressing Caddy proxy on `listenPort`. |
| `services.<name>.proxy.listenAddress` | `"127.0.0.1"` | Address the proxy binds: an IPv4 or IPv6 address; the default serves this machine only, `"0.0.0.0"` (the one spelling of every interface) exposes the agent. |
| `services.<name>.proxy.package` | `pkgs.caddy` | The reverse proxy that terminates the browser connection. |
| `services.<name>.units.<name>.description` | — | The unit's `Description`. |
| `services.<name>.units.<name>.env` | `{ }` | Extra `Environment=` entries (`PATH`, `TMPDIR` and `AI_SANDBOX_RELAX` are set by the module). |
| `services.<name>.units.<name>.exec` | — | The command nono runs inside the sandbox (argv, joined with spaces). |
| `services.<name>.units.<name>.extraService` | `{ }` | Extra `[Service]` settings (`Type`, `Restart`, `ExecStartPre`, ...). |
| `services.<name>.units.<name>.extraUnit` | `{ }` | Extra `[Unit]` settings (ordering against the service's other units). |
| `services.<name>.workdir` | `projectsDir`, expanded | Absolute working tree of the units (`--workdir`); the profile must grant it. |
| `sharedSkillsDir` | `"$HOME/.agents/skills"` | The cross-tool skills tree; read-only everywhere (a writable grant would be a cross-harness injection channel). |
| `tmpdirFallback` | `"/run/user/$UID"` | Root of a sandboxed CLI's `TMPDIR` when the environment sets none (a shell fragment); shared roots (`/`, `/tmp`, `/var/tmp`, `/run/lock`, `/dev/shm`, `/run/user`), however spelled, are rejected. |
| `unixMediation.enable` | `false` | nono's pathname `AF_UNIX` mediation with the socket grant inventory; stacks on the isolation. Off while nono denies granted sockets. |
| `variants.<name>.allow` | `[ ]` | Read+write paths. |
| `variants.<name>.allowFile` | `[ ]` | Read+write single files. |
| `variants.<name>.allowGpu` | `false` | Grant the GPU: `allow_gpu` in the profile and read access to `/run/udev`. |
| `variants.<name>.deny` | `[ ]` | Paths denied on top of `profileDefaults.deny`. |
| `variants.<name>.harness` | — | The harness (key of `harnesses`) this variant is layered on. |
| `variants.<name>.nonoArgs` | `[ ]` | Extra `nono run` flags of this variant's alias only. |
| `variants.<name>.read` | `[ ]` | Read-only paths. |
| `variants.<name>.readFile` | `[ ]` | Read-only single files. |
| `variants.<name>.setVars` | `{ }` | Environment variables set inside the sandbox (nono expands `$XDG_*` and `$HOME`). |
| `variants.<name>.suffix` | — | Appended to the harness's profile name (`<profileName>-<suffix>`); variants of one harness with the same suffix share the profile. |
| `variants.<name>.unixSocketSubtreeBind` | `[ ]` | Extra connect+bind socket subtrees under unix mediation. |
| `variants.<name>.x11` | `false` | A windowed application: X11 cookie, POSIX shared memory, `DISPLAY` kept, the X socket dir bound in (`--x11`). X11 has no client isolation. |

## Ports

The module never opens a firewall port by itself. The services' backends bind
loopback only; the proxy in front of a backend binds `127.0.0.1` by default
(`services.<name>.proxy.listenAddress`, `PROXY_LISTEN` without Nix), so only
this machine reaches it. An opencode-web agent has no authentication of its
own and can write your projects: to reach it from other machines, set the
address to one of this machine's (or `"0.0.0.0"`, every interface, IPv4 and
IPv6) and keep the port closed in your firewall to everyone you do not mean to
hand the agent to. The module touches no firewall option. Without Nix the
installer opens nothing either.

| Port | Bound to | Service | Notes |
| --- | --- | --- | --- |
| 15434 (proxy), 15435 (backend) | proxy: `127.0.0.1` (`proxy.listenAddress`); backend: `127.0.0.1` | `opencode-web` | Off by default (`services.opencode-web.enable`); a browser connects to 15434. |

## Isolation

`ai-sandbox-run` puts a bubblewrap namespace around `nono run`; nono's Landlock
domain stays as it is, inside. Landlock does not mediate `connect(2)` on
pathname unix sockets, so without the namespace an agent could reach the
session bus, the GPG agent, the Docker socket and more. The isolation is split
into layers, all on by default, and its name is also its relax token:

- `session`: the user runtime dir is hidden except the agent's own `TMPDIR`;
- `docker`: Docker and Podman sockets hidden;
- `system`: system D-Bus and avahi sockets hidden;
- `pid`: own PID namespace, only the agent's processes are visible;
- `tmp`: a private `/tmp`;
- `git`: `.git/hooks`, `config`, `config.worktree` and an in-project
  `core.hooksPath` read-only;
- `userns`: no nested user namespaces.

Three ways to switch it off:

- `<alias>_nono` (for example `claude_nono`): the same command through nono
  only, for one run.
- `AI_SANDBOX_RELAX=<layer>[,<layer>...] <alias>`: switch layers off for one
  run, for example `AI_SANDBOX_RELAX=session claude`; an unknown name is
  refused. `AI_SANDBOX_RELAX=browser` instead enables the URL relay that opens
  allowlisted URLs in your session (an OAuth login).
- With Nix, `programs.aiSandbox.isolation.enable` and `isolation.layers`; without,
  `ISOLATION=0` at install.

The wrapper fails closed: if the isolation cannot be built (a distribution that
restricts unprivileged user namespaces, for example), the agent does not start
and the message names the `_nono` alias. The design is in
`docs/specs/2026-09-26-sandbox-namespace-isolation-design.md`.

## Checks

Run one at a time, each capped (see `AGENTS.md`):

    nix build .#checks.x86_64-linux.<name>

`leaks` scans the source for personal data and first self-tests the scanner
on `checks/leaks/fixtures/{bad,good}`. The list of checks is in "Outputs".
`scripts/ai-sandbox-smoke.sh` is not a flake check: a live smoke test of the
isolation that you run by hand, outside any sandbox, after a switch (it needs
Nix).

## Licence

MIT, see `LICENSE`.
