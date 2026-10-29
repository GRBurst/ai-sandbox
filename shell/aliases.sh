# Sourced from ~/.bashrc or ~/.zshrc (bash and zsh): defines the sandbox aliases of every file
# in aliases.d. The installer replaces the placeholder below with the directory that holds
# aliases.d and variant.sh.
for ai_sandbox_file in "@SHELL_DIR@"/aliases.d/*.sh; do
  # shellcheck source=/dev/null
  [ -r "$ai_sandbox_file" ] && . "$ai_sandbox_file"
done
unset ai_sandbox_file
