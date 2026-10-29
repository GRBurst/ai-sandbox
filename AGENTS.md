# ai-sandbox: rules for agents

Public repository. Never write personal data into a tracked file: no host
names, no e-mail addresses (except `example.*` domains and the `.example`
top-level domain), no key ids, no `/home/<name>` paths (fixture users `coder`,
`tester`, `ai-test`, `u` are allowed), no RFC 1918 addresses, no ssh-scheme
remote URLs. The `leaks` check enforces this.

## Commands

Nix state in the agent sandbox (the default cache is not granted):

    export XDG_CACHE_HOME=$HOME/.cache/pi/nixcache XDG_DATA_HOME=$HOME/.cache/pi/nixdata

The flake is read through git: `git add` a new file before building. Commits
are unsigned: `git -c commit.gpgsign=false commit`.

Checks, one capped `nix build` each, run from the checkout. Never run `nix flake
check` (it evaluates every check in one process and is not capped):

    F=git+file://$PWD o=(--option eval-cache false) cap=$((20 * 1024 * 1024))
    names=$( (ulimit -v $cap && exec timeout -s KILL 300 nix eval --json "$F#checks.x86_64-linux" --apply builtins.attrNames "${o[@]}") ) &&
      names=$(jq -er '.[]' <<<"$names") || echo "LISTING FAILED"
    for c in $names; do
      (ulimit -v $cap && exec timeout -s KILL 900 nix build --no-link -L "$F#checks.x86_64-linux.$c" "${o[@]}") || echo "FAILED $c"
    done

Formatter: `nix build "$F#formatter.x86_64-linux" --no-link --print-out-paths`,
then `<out>/bin/alejandra <files>`.

## Rules

- Every new check is seen red once on a planted violation before it counts.
- Lock updates (`nix flake lock --update-input <name>`) are separate commits.
- Option names and the module key (`ai-sandbox#ai-sandbox`) are a public
  contract: change them only with a README update and a consumer note.
- Keep `README.md` `## Options` in step with the option tree (`readme-options`).

## Check lanes

Checks are grouped by what they guard (`checks/default.nix` merges the sets as
a disjoint union; a duplicate check name is an evaluation error):

- module: behaviour of the Home Manager and NixOS modules against fixture users;
- render: committed non-Nix artifacts equal the Nix output;
- shell: the wrapper under bwrap, the installer, `shellcheck`;
- meta: README and docs against the code, layering rules, the leak scan,
  formatting, the consumer example.

`shellcheck` takes an explicit file list: every tracked `*.sh` must be in
exactly one of `checked` and `excluded` in `checks/shellcheck.nix`.

## Render rule

`profiles/`, `shell/aliases.d/`, `shell/aliases-nono.d/`, `services/`, `services-nono/`,
`sysctl/` and `install/` are generated. Only `nix run .#render` writes them;
never edit them by hand. The `render-*` checks diff the committed files against
the Nix output.

## Downstream contract

`checks/module/lib.nix` and `checks/module/profile-rows.nix` are read by
downstream repositories' checks. Renaming either, or an attribute they export,
is a breaking change: announce it in the commit message.

## Commits

History becomes public. A commit message and every tracked file name no
private host, user, local path, planning document or task id. One commit per
logical change; lock updates stay separate.
