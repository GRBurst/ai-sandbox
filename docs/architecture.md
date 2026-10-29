# Architecture

Status: final for the first release. The boundaries, the render principle, the
artifact map, the limits without Nix, the contract with downstream checks and
the decision register are settled.

## What this repository is

The AI sandbox for coding agents: nono profiles per harness, shell aliases that
run the agents through the isolation wrapper `ai-sandbox-run`, optional
sandboxed web-UI services, and one sysctl. It works without Nix (an installer
over committed artifacts); the Home Manager and NixOS modules are first-class
support for frictionless use with Nix. The isolation itself is described in
[the isolation design extract](specs/2026-09-26-sandbox-namespace-isolation-design.md).

## Boundaries

- Inputs: `nixpkgs` and `home-manager`, for the checks. Consumers `follows`
  their own.
- The repository imports nothing from any other AI repository and knows no
  agent beyond the neutral harness presets (`claude`, `opencode`, `pi`, `agy`).
  Other layers import this one; there is no back edge.
- The modules read no `osConfig`, no option tree they do not import, no host
  option namespace (`my.*`) and set no firewall option: service ports are
  documented in the README, never opened. The `boundary` check enforces this.
- No private data: the `leaks` check scans the source for personal data, and
  its scanner is self-tested on fixtures.
- Option names and the module keys (`ai-sandbox#ai-sandbox`,
  `ai-sandbox#ai-sandbox-nixos`) are a public contract.

## Layout

```
flake.nix flake.lock LICENSE README.md AGENTS.md CLAUDE.md
modules/home-manager/*.nix        the Home Manager module (key ai-sandbox#ai-sandbox)
modules/nixos/default.nix         the sysctl (key ai-sandbox#ai-sandbox-nixos)
packages/ai-sandbox-run/          the wrapper: sandbox-run.nix, the .sh sources, defaults.json,
                                  portable-preamble.sh
render/default.nix                render fixtures and the render derivation
profiles/ shell/ services/ services-nono/ sysctl/ install/   rendered artifacts (no Nix needed to use them)
shell/variant.sh shell/aliases.sh scripts/install.sh scripts/deps   hand-written
scripts/ai-sandbox-smoke.sh       live smoke test of the isolation, run by hand outside any sandbox
examples/existing-flake/ examples/without-nix/   a flake that adds the module; a user profile layered on a shipped one
checks/                           module/ (behaviour), render, shell, meta checks
docs/                             this file, docs/specs/
```

## Principles

- **P1 Nix renders, plain files ship.** Every non-Nix artifact with a Nix
  counterpart is the evaluated output of a render fixture (a documented
  configuration of this repository's own module), committed, written only by
  `nix run .#render` and compared by a `render-*` check. A hand edit fails the
  check.
- **P2 Without Nix, nothing calls `nix`.** The install and run paths need only
  the tools in the README's "Without Nix" table; `readme-deps` ties the table to
  the installer's list (`scripts/deps`).
- **P3 One source for shared behaviour.** `sandbox-run.sh`, the URL check, the
  relay and the shim are used unchanged by the Nix wrapper and the installed
  one; only the preamble differs: store paths (Nix) or absolute paths resolved
  at install time.
- **P4 Customise through nono's `extends`.** Without Nix, extra profiles extend
  a shipped one and the variant helper defines the aliases; shipped files are
  never edited (reinstalling overwrites them).
- **P5 Nix never reads a rendered artifact.** The module is the source; the
  artifacts are its output.

Isolation invariants hold on both paths: every profile has exactly one
`extends`, every alias has its `<alias>_nono` twin, `AI_SANDBOX_RELAX`
semantics are fixed, and the wrapper fails closed.

**Invariant E** (the one the rest follows from): every nono profile has one
`extends` entry, and its ancestry holds exactly one registry pack. nono's
`extends` only adds, and the profile schema has no way to remove an inherited
filesystem path, so a second base could never be taken back. The Nix module
flattens: every profile it emits, twins and variants included, extends its
harness's pack directly, not the harness's profile. Without Nix a profile of
your own (such as `examples/without-nix/pi-claude-notes.json`) chains to one
shipped profile, which extends the pack. The module checks assert the flat form
on every emitted profile (the message "isolation invariant E"); `extends-shape`
asserts one `extends` on every shipped and example profile, naming a pack for a
shipped one and a shipped profile for an example.

## Artifacts and their checks

| Artifact | Source | Check |
|---|---|---|
| `profiles/*.json`, `profiles/NONO_VERSION` | the render fixture's `xdg.configFile."nono/profiles/*"`, `jq -S`; the nono version of the repo's lock | `render-profiles` |
| `shell/aliases.d/`, `shell/aliases-nono.d/` | the fixture's `home.shellAliases` and `home.sessionVariables` (isolation on, off) | `render-aliases`; `install-sh` reads them back in bash and zsh |
| `services/`, `services-nono/` | the unit files Home Manager builds for the fixture (through the wrapper, isolation off) | `render-units` |
| `sysctl/60-ai-sandbox.conf` | `nixosModules.default` evaluated | `render-sysctl` |
| `install/{harnesses.json,services.json,dirs}` | the fixture's harnesses, services and activation dirs | `render-install` |
| `shell/variant.sh` | hand-written; the one re-implementation of the alias builder | `variant-sh` (byte for byte against the Nix strings, bash, zsh and dash) |
| `shell/aliases.sh`, `scripts/install.sh`, `scripts/deps` | hand-written | `install-sh`, `readme-deps`, `shellcheck` |
| `packages/ai-sandbox-run/portable-preamble.sh` | hand-written template | `run-portable` (the wrapper suite against the installed wrapper), `preamble-vars` inside it |
| `examples/existing-flake/` | hand-written | `existing-flake-example` |
| `examples/without-nix/*.json` | hand-written | `extends-shape` |
| `README.md` | hand-written | `readme-options`, `readme-deps`, `readme-sections`, `doc-refs` |
| `scripts/ai-sandbox-smoke.sh` | hand-written, run by hand after a switch (needs Nix) | `shellcheck` |

## The installer

`scripts/install.sh install` works in this order and writes nothing
before every check has passed: take each option from the environment or, when
it is empty, from the record of the last install
(`$XDG_DATA_HOME/ai-sandbox/options`; `default` drops it); validate the switches
(`GPU`, `ISOLATION`, `PROXY_LISTEN`; `PREFIX` and the XDG directories, none of
them looking like a placeholder, are checked first), the setting file
`sysctl/60-ai-sandbox.conf`, the manifest and the names of `SERVICES`; resolve
every tool of `scripts/deps` to an absolute path; check `HARNESSES`, the
registered layers, the cache directories and the services (working tree,
commands on `SERVICE_PATH`, entries outside every grant); last preflight `bwrap`
when the isolation is on. The files are then staged through `put`, which
refuses a destination that exists, is not in the manifest and differs, one
that is a directory, and one whose directory cannot be made or written; the
cache and data directories and the manifest's are checked the same way
(`check_make_dirs`), and `check_removable` refuses a unit the run would remove
while it is enabled. Only after all have passed are they written: the wrapper
(assembled from the preamble and `sandbox-run.sh`), the selected profiles and
the registered layers (later wins), the records of the layers and the options,
the shell files, the service units and Caddyfiles; then the cache and data
directories (`0700`) are made, the files of the last install that this one did
not write are removed, and last the manifest
(`$XDG_DATA_HOME/ai-sandbox/manifest`) is written. It prints the line that sources
`aliases.sh`, the `PATH` hint, the `systemctl --user` lines (with the proxy address
and port they open, and `try-restart` for a unit that changed or whose Caddyfile, profile or wrapper changed) and the `sudo tee` lines
that write the pinned setting, and runs none of them. `uninstall` removes
exactly the manifest, and refuses while a unit of it is enabled.

The rendered proxy files are the module's for its default address,
`127.0.0.1`; `PROXY_LISTEN` rewrites their `bind` line and the proxy unit's
`Description` as the module would (`install-sh` compares both with the
module's output for other addresses).

## Limits without Nix

What a user without Nix does not get, and what replaces it:

| Nix gives | Without Nix |
|---|---|
| Typed options, assertions at evaluation | the installer's preflight; `variant.sh` refuses a bad `TMPDIR` fallback; no other validation |
| Render-time hooks (`editor.*`, `profileDefaults`, `packDefaults`) | `extends` user profiles (additive only); removing a shipped grant needs a copied profile under a new name |
| Activation (`nonoProfileReclaim`, directories on every switch) | rerun the installer; the directories are made once at install |
| Generations, atomic switch, rollback | `git pull && scripts/install.sh install` (the options and layers are recorded); `scripts/install.sh uninstall` |
| A pinned closure (nono, bwrap, socat, caddy) | distribution versions with the minimums of the README; nono's packs are fetched at run time on both paths |
| The NixOS module's sysctl and its firewall comment | `sysctl/60-ai-sandbox.conf`, installed by hand with the printed `sudo` line |
| fish aliases | bash and zsh |

## Downstream contract: `checks/module/`

Repositories that build on this one (and the host configuration that consumes it)
import two files of `checks/module/` from their `ai-sandbox` input instead of
copying them:

- `lib.nix`: `{pkgs, lib, home-manager}: {…}`, the fixtures and helpers of the
  module checks. The names downstream code uses: `aiFixtureWith` (the module plus
  one override), `aiFailedWith` and `aiFailsWith` (failed assertions as data),
  `mkAssertionCheck`, the fixtures `aiNoNvf`, `aiNoSandbox`, `aiNoGpu`,
  `aiNoIsolation`, `aiNoDisplay`, `aiMediation`, the profile and alias
  helpers (`aiProfile`, `aiPack`, `aiEmittedProfiles`, `aiUnixSocketGrants`, `aiGeneratedAliases`,
  `aiExpectedAlias`, `aiExpectedGpuAlias`, `aiExpectedNonoAliases`,
  `aiAllAliasesOf`, `aiNonoTwinsOf`, `aiEveryAliasOf`, `aiTmpdirExpr`) and the
  profile-name lists (`aiAllProfileNames`, `aiBaseProfileOf`).
- `profile-rows.nix`: `{lib, helpers}: {home, files ? true, aliases ? true}: [{condition; message;}]`,
  the profile invariants as rows over one evaluated home. A message is the same
  for every home, so a consumer may combine the rows of several homes.

Renaming either file, or any attribute named here, is a breaking change: it is
announced in the commit message, and a consumer's lock bump fails loudly
instead of drifting. `AGENTS.md` carries the same rule.

## Decision register

| # | Decision | Why |
|---|---|---|
| AD1 | Module files at `modules/home-manager/*.nix`, the wrapper at top-level `packages/ai-sandbox-run/`, the copied module checks at `checks/module/`, other checks at `checks/<name>.nix`; check names are unprefixed; `checks/default.nix` merges its sets with a disjoint union that throws on a duplicate name | the wrapper is a package of its own; one flat check namespace without silent shadowing |
| AD2 | Outputs other layers read are public and read-only: `harnessProfiles` (harness → profile name), `serviceUnits` (service → unit names), `runPackage`; the rest of `internal.*` stays internal and out of the README | a consumer needs them; renaming a public option after publication breaks consumers |
| AD3 | A harness has an optional `package` (default `null`, installed iff non-null and the harness enabled); there is no separate `command` or `alias.enable` (attribute name = command = alias) | frictionless with Nix: the CLI installs next to its profile; the two dropped options have no consumer |
| AD4 | The wrapper's `.sh` files are frozen text: they are the wrapper derivation, and the installer assembles the same bytes; the isolation design they cite is answered by a scrubbed extract in `docs/specs/` | one source for both paths (P3); every citation resolves inside the repository (`doc-refs`) |
| AD5 | Services keep the `agent-web` vocabulary (`%t/agent-web/<unit>`, `$XDG_CONFIG_HOME/agent-web/<name>/Caddyfile`, the activation list `agentWebDirs`) as the documented name for "agent web UI" services | the name identifies nobody; a rename changes unit texts and live runtime paths for no function |
| AD6 | `render-units` copies the unit files Home Manager itself builds for the render fixture and replaces store paths and sentinels with placeholders; no second INI serialiser | compares byte for byte what a Nix user gets |
| AD7 | Two alias sets ship: `shell/aliases.d/` (isolation on) and `shell/aliases-nono.d/` (isolation off), one file per command and variant suffix, `00-session.sh` for the session variables; likewise two unit sets, `services/` (through the wrapper) and `services-nono/` (isolation off: no wrapper and no `AI_SANDBOX_RELAX=` line) | the installer's `ISOLATION=0` and `GPU=0` select files; every line is still rendered from Nix |
| AD8 | The installer reads rendered manifests: `install/harnesses.json` (harness → profile, variants), `install/services.json` (service → profile, units, Caddyfile, data dirs, working tree, the commands its units run) and `install/dirs` | it selects files without knowing Nix naming rules |
| AD9 | `scripts/install.sh` reads its tool list from `scripts/deps` only | the README table equals that file (P2) |
| AD10 | The portable wrapper is `portable-preamble.sh` (a template with `@var@` placeholders for the injected variables) plus `sandbox-run.sh` verbatim; `preamble-vars` checks that the Nix preamble and the portable one assign the same variable set | a variable added on one side only fails at build time, not at a user's first run |
| AD11 | The `boundary` check carries the layering rules: no `osConfig`, no other layer's option namespace, no firewall option on a non-comment line of `modules/` or `packages/`; no `.nix` under `modules/` names a rendered artifact directory | the boundaries above stay enforced by code |
| AD12 | The render fixture is the module with every default, stub packages for `nono` and `caddy` and sentinel home, config and cache directories; placeholders after substitution are `@HOME@`, `@XDG_CONFIG_HOME@`, `@XDG_CACHE_HOME@`, `@SERVICE_PATH@`, `@AI_SANDBOX_RUN@`, `@NONO@`, `@CADDY@`; the render fails if a store path survives | a real Home Manager evaluation with nothing heavy built; every store path in an artifact is one of three known outputs |
| AD13 | The project-directory variant used in examples, docs and checks is `variants.pi_notes = {harness = "pi"; suffix = "notes"; allow = ["$HOME/src/notes"];}`: profile `pi-claude-notes`, aliases `pi_notes` and `pi_notes_nono` | a neutral example that names no one's directory layout |
| AD14 | `shellcheck` takes explicit lists: checked files (`-s bash`) and excluded files (frozen wrapper sources, the portable preamble, rendered alias files); every tracked `*.sh` is in exactly one list | frozen files cannot be fixed without changing the wrapper; they stay covered as assembled scripts |
| AD15 | Without Nix, `SERVICE_PATH` (default `/usr/local/bin:/usr/bin:/bin`) replaces `@SERVICE_PATH@`; the installer refuses when an entry is missing, user-writable or user-owned, lies in the service's working tree or in a read-write grant of its installed profile (a layer's, if one overrides it), or when `opencode` is not found on it | the unit runs `opencode` with `--strict-broker-path`, which refuses a `PATH` directory that a filesystem grant covers or that the user can write (an owner can chmod it back); failing at install beats a unit that never starts |
