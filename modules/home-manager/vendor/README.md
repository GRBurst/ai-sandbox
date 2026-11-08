# Vendored third-party files

## `nolabs-ai-claude.policy.json`

- Source: the nono registry pack `nolabs-ai/claude`, version 0.1.4
  (`nono pull nolabs-ai/claude@0.1.4`), artifact `policy.json`, which nono
  installs as the profile `claude` (`profiles/claude.json` in the pack store).
- Upstream: <https://github.com/nolabs-ai/nono-packs>, tag `claude-v0.1.4`,
  file `claude/policy.json`.
- sha256: `7605ee6226e4c452587c3663b6b00b9b0609fa2c27ceb961abd7d3a7ed4ab8a0`
  (recorded in `../bases.nix`; the `vendored-packs` check compares it and the
  version with the pin in `scripts/packs`).
- Licence: Apache License 2.0, by nolabs-ai (the pack's `package.json` and the
  upstream repository's `LICENSE`). The full text is in `LICENSE-Apache-2.0`
  beside this file, copied from the upstream repository. Upstream ships no
  `NOTICE` file. The rest of ai-sandbox is MIT (`LICENSE` at the root).

The file itself is unmodified, byte for byte.

### Modified derivative: the base `ai-sandbox-claude`

`../bases.nix` derives the nono profile `ai-sandbox-claude` from it. The Home
Manager module emits it as `nono/profiles/ai-sandbox-claude.json`, and
`nix run .#render` writes it to `profiles/ai-sandbox-claude.json` for installs
without Nix. That profile is a modified version of the file above, changed by
ai-sandbox as follows. Its `meta.description` carries this notice in short.

- `extends` is `["default"]` (a list) instead of `"default"`.
- `meta` is replaced by the base's own name and a modification notice.
- `filesystem.allow` drops `$HOME/.claude` and adds `$HOME/.claude-sandbox`.
- `filesystem.allow_file` drops `$HOME/.claude.json`, `$HOME/.claude.json.lock`
  and `$HOME/.claude.lock`.
- The session hook runs from `$NONO_PACKAGES/nolabs-ai/claude/...` instead of
  `$PACK_DIR/...`.
- `environment.set_vars` adds Claude Code's config-dir variable, set to
  `$HOME/.claude-sandbox`, and `CLAUDE_CODE_PLUGIN_DIRS=$NONO_PACKAGES/nolabs-ai/claude`.
- The rendered JSON has its keys sorted (`jq -S`).

Everything else is the vendored file unchanged (the `bases` check asserts it).

## `nolabs-ai-opencode.policy.json`

- Source: the nono registry pack `nolabs-ai/opencode`, version 0.1.3
  (`nono pull nolabs-ai/opencode@0.1.3`), artifact `policy.json`, which nono
  installs as the profile `opencode` (`profiles/opencode.json` in the pack
  store).
- Upstream: <https://github.com/nolabs-ai/nono-packs>, tag `opencode-v0.1.3`,
  file `opencode/policy.json`.
- sha256: `88dce4b22eefaaba4a298d28e8d38b14fab5a92d2ec075ac34d4f259d8c87a4a`
  (recorded in `../bases.nix`; the `vendored-packs` check compares it and the
  version with the pin in `scripts/packs`).
- Licence: Apache License 2.0, by nolabs-ai (the pack's `package.json` and the
  upstream repository's `LICENSE`, the text in `LICENSE-Apache-2.0` beside
  this file). Upstream ships no `NOTICE` file.

The file itself is unmodified, byte for byte.

### Modified derivative: the base `ai-sandbox-opencode`

`../bases.nix` derives the nono profile `ai-sandbox-opencode` from it, emitted
and rendered like `ai-sandbox-claude` (`profiles/ai-sandbox-opencode.json`).
That profile is a modified version of the file above, changed by ai-sandbox as
follows. Its `meta.description` carries this notice in short.

- `extends` is `["default"]` (a list) instead of `"default"`.
- `meta` is replaced by the base's own name and a modification notice.
- `filesystem.allow` drops `$HOME/.claude` and `$HOME/.codex`.
- The session hook runs from `$NONO_PACKAGES/nolabs-ai/opencode/...` instead
  of `$PACK_DIR/...`.
- `environment.set_vars` adds Claude Code's config-dir variable, set to
  `$HOME/.local/share/opencode/claude`.
- The rendered JSON has its keys sorted (`jq -S`).

Everything else is the vendored file unchanged (the `bases` check asserts it).
