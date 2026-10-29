# ai-sandbox-url-check URL -- exit 0 iff URL may be opened.
# Allowlist: AI_SANDBOX_OPEN_URLS = nono's resolved .open_urls. Only ever
# NARROWER than nono (spec K6): exact https origin, localhost only if allowed.
url=${1-}
allow=${AI_SANDBOX_OPEN_URLS:-'{"allow_origins":[],"allow_localhost":false}'}
[ "${#url}" -le 2048 ] || exit 1
case $url in *[[:cntrl:]]* | *[[:space:]]*) exit 1 ;; esac
# No userinfo, no percent-encoding in the authority: the host is exactly what
# follows "://" up to an optional port and the first "/".
re='^(https?)://([A-Za-z0-9.-]+|\[::1\])(:[0-9]{1,5})?(/.*)?$'
[[ $url =~ $re ]] || exit 1
scheme=${BASH_REMATCH[1]}
host=${BASH_REMATCH[2],,}
port=${BASH_REMATCH[3]}
case $host in
  localhost | 127.0.0.1 | '[::1]')
    if jq -e '.allow_localhost == true' <<<"$allow" >/dev/null; then exit 0; fi
    exit 1
    ;;
esac
[ "$scheme" = https ] || exit 1
jq -e --arg o "https://$host$port" 'any(.allow_origins[]; ascii_downcase == $o)' <<<"$allow" >/dev/null
