# `xdg-open` inside the isolation. Default: refuse (spec R12). With the URL
# relay (AI_SANDBOX_RELAX=browser): forward one line, relay answers ok/refused.
url=${1-}
sock=${AI_SANDBOX_URL_SOCK-}
if [ -z "$sock" ] || [ ! -S "$sock" ]; then
  printf 'ai-sandbox: URL opening is blocked; open it by hand or rerun with AI_SANDBOX_RELAX=browser: %s\n' "$url" >&2
  exit 1
fi
reply=$(printf '%s\n' "$url" | socat -t 5 - "UNIX-CONNECT:$sock") || reply="refused: URL relay unreachable"
if [ "$reply" = ok ]; then exit 0; fi
printf 'ai-sandbox: %s: %s\n' "$reply" "$url" >&2
exit 1
