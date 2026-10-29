# The AI sandbox as a Home Manager module (this repository's `homeModules.default`):
# nono profiles, aliases, the isolation wrapper. Public option tree: `programs.aiSandbox`.
# Parts: the scalar options, harnesses, profile files, variants, aliases, home, services.
{
  key = "ai-sandbox#ai-sandbox";
  imports = [./options.nix ./harnesses.nix ./variants.nix ./profiles.nix ./aliases.nix ./home.nix ./services.nix];
}
