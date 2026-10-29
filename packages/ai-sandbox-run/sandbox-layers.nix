# Isolation layer names (spec 2026-09-26-sandbox-namespace-isolation, D3), in
# the order ai-sandbox-run applies them. They are also the AI_SANDBOX_RELAX
# tokens (plus "browser"). Own file: the option type needs the list before
# config exists, and checks/ai-sandbox-run imports the same list. The list
# lives in defaults.json, which the installer reads too.
(builtins.fromJSON (builtins.readFile ./defaults.json)).layers
