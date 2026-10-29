# ai-sandbox-url-relay: per-connection handler of the URL relay, run by socat
# OUTSIDE the isolation. stdin: one URL line from the shim; stdout: "ok" or
# "refused: ...". Env: AI_SANDBOX_OPEN_URLS (JSON, see ai-sandbox-url-check).
# xdg_open is injected by sandbox-run.nix.
IFS= read -r url || true
if ai-sandbox-url-check "$url"; then
  setsid -f "$xdg_open" "$url" </dev/null >/dev/null 2>&1
  echo ok
else
  echo "refused: not in this profile's open_urls"
fi
