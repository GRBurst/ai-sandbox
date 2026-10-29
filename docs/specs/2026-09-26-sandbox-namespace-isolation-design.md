# Sandbox namespace isolation — hide host sockets and processes from agents

Extract of the design behind `ai-sandbox-run`. It keeps the goal, the
vocabulary, the layer table and the decisions, facts, requirements, scenarios,
review-focus items, assumptions and risks that the code and the checks of this
repository cite, and the names of the groups of the wrapper suite; the original
numbering is kept, so a citation such as `(spec R9)` resolves here. Every id
the sources cite is defined here as a bold item (`- **R9** ...`); the check
`doc-refs` fails on one that is not. Everything that named a particular machine
or user was left out.

## 1. Purpose

**Goal.** An agent started through any generated sandbox alias or sandboxed
web-UI service can no longer reach the user's desktop session, credential
agents, container runtime or other processes, and still does everything it
does without the isolation: network, Nix, name resolution, its own temp,
runtime and cache dirs, the project, git.

**Why.** Landlock ABI ≤ 8 does not mediate `connect(2)` on pathname UNIX
sockets, so nono's filesystem grants do not confine them. From inside a nono
profile the session bus and the Wayland socket can be connected to by absolute
path although `nono why` reports `path_not_granted`. The same gap leaves
reachable: the user manager's private socket (start unsandboxed units), the GPG
agent and its SSH socket (`SSH_AUTH_SOCK`: the user's SSH keys, GPG signing),
PipeWire/Pulse, `/run/docker.sock` (a member of group `docker` is root), the
system D-Bus and avahi.

**Walkthrough.** The user starts an agent through its alias in a project. The
agent works as before; none of the sockets above exists for it, `ps` shows only
its own processes, its writes to `.git/hooks` fail. For a task that needs the
session bus the user types the `_nono` alias or `AI_SANDBOX_RELAX=session
<alias>`. For an OAuth login that needs the browser,
`AI_SANDBOX_RELAX=browser <alias>`.

## 2. Vocabulary

| Term | Meaning |
|---|---|
| **isolation** | The namespace put around `nono run` by the wrapper. nono's Landlock domain stays as is, inside it. |
| **wrapper** | `ai-sandbox-run`: builds the isolation and runs the given command in it. |
| **layer** | One independently switchable part of the isolation (D3). Its name is also its relax token. |
| **relax** | Switching a token off for one run via the environment variable `AI_SANDBOX_RELAX`. |
| **nono alias** | `<alias>_nono`: the same command through nono only, the alias string as it is without the isolation. |
| **hidden** | A path that does not exist inside the isolation (`test -e` false), although it exists outside. For the `docker` and `system` layers: no longer a socket (covered by `/dev/null`, `test -S` false, connect fails), because a single file cannot be removed from view without hiding its parent directory. |
| **mediation** | nono's `linux.af_unix_mediation = "pathname"`. |
| **URL relay** | The allowlist-checking forwarder that opens URLs in the user's session on behalf of a sandboxed process. |

### Layers

All on by default (D3). The token is the layer name; `browser` is not a layer
but enables the URL relay (D7).

| Layer | Effect |
|---|---|
| `session` | the user runtime dir is hidden except the agent's own `TMPDIR` |
| `docker` | Docker and Podman sockets hidden |
| `system` | system D-Bus and avahi sockets hidden |
| `pid` | own PID namespace: only processes started inside are visible |
| `tmp` | private `/tmp`; display GPU twins see the X11 socket directory and nothing else of `/tmp` |
| `git` | repository metadata (`.git/hooks`, `config`, `config.worktree`, an in-project `core.hooksPath`) read-only |
| `userns` | no nested user namespaces |

## 3. Verified facts

- **F3** Mediation with grants for the Nix daemon, nscd, a `$TMPDIR` subtree and
  the editor runtime dir was tried: the Nix daemon connected 9 of 20 times, an
  own socket in `$TMPDIR` 0 of 10 times, nono reported "target could not be
  canonicalized". This reproduces open upstream nolabs-ai/nono#1970 (nono
  0.78.0) and #1420 (rate limiter). nono's docs add that allowed connects are
  raceable by multi-threaded processes.
- **F6** In an unprivileged user namespace, root-owned files appear owned by
  `nobody` (`/nix/store` → `nobody`).
- **F7** Upstream bubblewrap removed setuid mode. bubblewrap runs (user and pid
  namespace, tmpfs) inside a Nix build sandbox when user namespaces are
  available there; that sandbox has a private writable `/tmp` in which sockets
  can be created, and no `/run`.

## 4. Decisions

- **D1 Mechanism: bubblewrap around nono, unprivileged user namespace.** Wins
  over systemd-run (system sockets stay visible, environment forwarding), over
  mediation (F3), over setuid (F7) and over waiting for Landlock ABI 9. Around,
  not inside: nono's Landlock domain cannot build namespaces, and nono's
  supervisor must be inside too.
- **D2 One wrapper** for every entry point: sandbox aliases, GPU twins, login
  helpers, web-UI services. Alternative: per-entry bwrap lines — a second copy
  to drift.
- **D3 Layers, all on by default** (table above). Alternative: one
  all-or-nothing switch — forces `_nono` for any single need.
- **D4 No `--new-session`; pin `dev.tty.legacy_tiocsti = 0` instead.** It is
  what closes TIOCSTI, and `--new-session` breaks job control. The NixOS module
  pins the sysctl to the kernel default.
- **D5 Three off switches:** `<alias>_nono` (whole isolation, per run),
  `AI_SANDBOX_RELAX` (per token, per run), `programs.aiSandbox.isolation.*`
  (per user). The suffix `_nono` names what is left; `_bare` was rejected as
  misleading, `_host` and `_nobwrap` as mechanism names.
- **D6 Fail closed.** No isolation → no agent; the message names the nono
  alias. Alternative: silent fallback — would make the isolation unobservable.
- **D7 URL opening: refused by default, the `browser` token enables the URL
  relay.** The relay enforces the profile's own `open_urls`, so a sandboxed
  process gains nothing over what nono already permits. Rejected: a filtered
  D-Bus proxy (filters methods, not URLs; would bypass the allowlist). Services
  never get the relay.
- **D8 Mediation prepared, off** (`programs.aiSandbox.unixMediation.enable =
  false`). When upstream is fixed it stacks on the isolation; it does not
  replace it (F3 race).
- **D9 No IPC or network namespace.** SysV shm would break XShm in display GPU
  twins; agents need the network and web UIs need loopback.
- **D10 The git layer determines paths without running git in the
  repository.** A repository's config can execute code (e.g. `core.fsmonitor`)
  when git operates on it. One config file is read alone, includes off, from
  `/`, so git discovers no repository (case `git-no-exec` of the wrapper
  suite; also cited as RF3).

## 5. Scenarios

- **S1.1** Given `pi` started in a project, When the agent tests every socket
  path of §1 with `test -e`, Then each test is false.
- **S1.4** Given `pi` started, When the agent binds a socket in `$TMPDIR` and
  connects to it 10 times, Then 10/10 connects succeed.
- **S2.1 (refusal)** Given `pi` started, When the agent lists numeric entries of
  `/proc`, Then none belongs to a process outside the isolation.
- **S2.2 (refusal)** Given a repo at the cwd, When the agent writes
  `.git/config` or creates `.git/hooks/pre-commit`, Then the write fails and the
  file is unchanged on the host.
- **S2.3 (refusal)** Given a repo whose `core.hooksPath` is `.githooks` inside
  the project, When the agent writes `.githooks/pre-commit`, Then the write
  fails.
- **S2.4 (refusal)** Given `pi` started, When the agent creates a user
  namespace, Then it fails.
- **S2.5** Given `pi` started, When the agent creates `/tmp/x`, Then it succeeds
  and the host's `/tmp/x` does not exist.
- **S2.6 (refusal)** Given `pi` started without relax, When a URL is opened via
  `xdg-open` or `$BROWSER`, Then it exits non-zero, stderr contains the URL and
  `AI_SANDBOX_RELAX=browser`, and no browser opens.
- **S3.1** Given `AI_SANDBOX_RELAX=git,pid`, When `pi` starts, Then stderr
  contains `ai-sandbox-run: relaxed: git,pid`, `git config --local` succeeds,
  host PIDs are visible, and S1.1 still holds.
- **S3.2 (refusal)** Given `AI_SANDBOX_RELAX=gti`, When `pi` starts, Then it
  exits 2, stderr lists the valid tokens, and no agent process is started.
- **S3.5** Given `AI_SANDBOX_RELAX=browser`, When `https://github.com` is opened
  from inside `pi`, Then the user's browser opens it.
- **S3.6 (refusal)** Given `AI_SANDBOX_RELAX=browser`, When `https://example.com`
  or `https://claude.ai@evil.example/` is opened, Then it is refused with a
  message and no browser opens.
- **S4.1 (refusal)** Given a shell inside a running sandbox, When `pi` is run,
  Then it exits non-zero, stderr names `pi_nono`, and no agent starts.
- **S4.2 (refusal)** Given the wrapper invoked with a relative or missing
  `TMPDIR`, When it starts, Then it exits 1 naming `TMPDIR`.
- **S5.1 (repetition)** Given a repo without `.git/config.worktree` and without
  `core.hooksPath`, When `pi` runs and exits twice, Then the project's file list
  (`git status --porcelain --ignored`, `find`) equals the one before.
- **S5.2 (repetition)** Given `AI_SANDBOX_RELAX=browser pi` exited, When
  processes and `$TMPDIR` are listed, Then no URL relay process and no relay
  socket remain, and a second run behaves identically.
- **S6.1** Given `claude_gpu` with `gpu.display = true`, When an X11 client is
  started inside, Then it connects to the X server, and the Wayland socket is
  hidden.
- **S7.2 (refusal)** Given `AI_SANDBOX_RELAX=browser,session` in the user
  manager environment, When a sandboxed service unit starts, Then its isolation
  is not relaxed.

## 6. Requirements

- **R1** Every generated sandbox alias, GPU twin, login helper and sandboxed
  service runs its command inside the isolation, around nono.
- **R2** Hidden inside the isolation: all of the user runtime dir except the
  agent's own `TMPDIR`; the Docker and Podman sockets; the system D-Bus and
  avahi sockets, each when its layer is on.
- **R3** Unaffected: the Nix daemon, nscd, systemd userdb, `TMPDIR` (read,
  write, create and connect sockets), the editor's runtime dir, the project,
  caches, network, OSC 52.
- **R5** With `tmp` on, `/tmp` is private per session; display GPU twins see
  the host's X11 socket directory and nothing else of the host's `/tmp`.
- **R6** With `git` on, for the repository whose `.git` directory is at the cwd:
  `hooks/`, `config`, `config.worktree` and an in-project `core.hooksPath` are
  read-only; determined without running git inside that repository.
- **R8** `AI_SANDBOX_RELAX` accepts a comma-separated subset of the tokens
  `session docker system pid tmp git userns browser`; an unknown token exits 2
  before anything starts; relaxed tokens are announced on stderr once.
- **R9** Every generated alias has a nono alias `<alias>_nono` equal to that
  alias's string without the isolation.
- **R10** `programs.aiSandbox.isolation.enable` (bool, default true) and
  `.layers` (list of layer names, default all) are typed options;
  `enable = false` restores every non-isolated alias exactly and emits no nono
  aliases.
- **R11** If the isolation cannot be built, nothing runs; exit non-zero with the
  underlying error and the nono alias name when there is one.
- **R12** URL opening from inside is refused by default with the URL and the
  relax hint on stderr. With `browser` relaxed, a URL is opened in the user's
  session iff it matches the profile's resolved `open_urls`; services ignore
  `AI_SANDBOX_RELAX`.
- **R14** `programs.aiSandbox.unixMediation.enable` (default false); when true
  every profile carries `linux.af_unix_mediation = "pathname"` and exactly:
  connect to the Nix daemon and nscd sockets; connect and bind below `$TMPDIR`
  and, if the editor grants are on, below the profile's editor runtime dir;
  display twins connect in `/tmp/.X11-unix`.
- **R19** While a layer that hides a directory is on (`session`, `tmp`), no
  environment variable whose value names a path strictly below that directory,
  other than below the agent's `TMPDIR`, the cwd or the X11 socket dir, reaches
  the command; relaxing the layer restores them.

## 7. Assumptions

- **A3** The Nix build sandboxes of the machines that run the checks allow user
  namespaces (F7). A builder without them fails the `ai-sandbox-run` and
  `run-portable` checks; the message names the cause.

## 8. Risks

- **K1** A tool refuses to work because root-owned paths show as `nobody` (F6);
  expected: cross-session messaging in some agents. Mitigation: the `_nono`
  alias. Not relaxable (inherent).
- **K2** `nono ps`, `attach` and `stop` misbehave with namespace-local PIDs.
  Mitigation: relax `pid`.
- **K3** A future bwrap, kernel or distribution change disables unprivileged
  user namespaces → every alias fails (D6). Intended; the message names the
  nono alias.
- **K4** Something an agent legitimately used over a hidden socket (ssh push,
  Docker, notifications, keyring, `systemctl --user`) silently stops working.
  Mitigation: documented, relax tokens.
- **K6** The URL relay's allowlist parsing diverges from nono's. Mitigation:
  the relay only ever narrows (exact origin match, https only, localhost only
  if allowed).

## 9. Review focus

Inputs the scenarios do not name; each has its case in the wrapper suite.

- **RF1** `TMPDIR` is an ancestor of the project and lies under a tmpfs'd dir
  (e.g. `TMPDIR=/tmp/x`, project `/tmp/x/repo`): the git overlays must stay
  read-only. Case `git-ro-under-tmpdir`.
- **RF2** The project itself is under `/tmp` or the runtime dir: it must stay
  visible and writable. Case `pwd-under-tmp`.
- **RF3** A repository whose config carries `core.fsmonitor`: starting the
  wrapper in it must not execute it. Case `git-no-exec` (D10).
- **RF4** `core.hooksPath` pointing outside the project or at the project root:
  nothing outside is bound, the project is not made read-only. Cases
  `git-hookspath-out-of-tree`, `git-hookspath-root`.
- **RF5** `AI_SANDBOX_RELAX` with duplicates or empty elements (`git,,git,`):
  accepted, announced once as `git`. Case `relax-announce`.

## 10. Groups of the wrapper suite

The sections of `checks/ai-sandbox-run/suite.nix`; the comments there name them.

- **T1.1** Arguments, relax tokens, `TMPDIR`, `PATH` (R8, S3.1, S3.2, S4.2, RF5).
- **T1.2** Hiding the session, Docker and system sockets (R2, S1.1, S1.4).
- **T1.3** `pid`, `userns`, `tmp` and the X11 socket directory (R5, S2.1, S2.4,
  S2.5, S6.1, RF2).
- **T1.4** The git layer (R6, S2.2, S2.3, S5.1, RF1, RF3, RF4).
- **T1.4b** In-tree git include targets read-only: a file included from
  `.git/config` (`include.path`, `includeIf.*.path`) is agent-writable config
  that could set `core.fsmonitor` or `core.hooksPath` for the user's next git
  command on the host, and `--no-includes` alone never looks at it. The git layer
  therefore reads `.git/config` and every in-tree include target, transitively,
  each alone and from `/`, and binds every existing in-tree target and in-tree
  `core.hooksPath` read-only; out-of-tree targets are left (D10).
- **T1.5** Fail closed (R11, S4.1).
- **T2.1** The URL check's table (R12, S3.6, K6).
- **T2.2** The shim refuses by default (S2.6).
- **T2.3** The relay (S3.5, S3.6, S5.2).
