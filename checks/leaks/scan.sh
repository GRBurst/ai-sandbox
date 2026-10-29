# Generic leak scan. usage: leak-scan <dir>
# Prints `./path:line:[rule] matched text` for every hit on stderr; exits 1
# if there is any.
# Generic patterns only: a list of private terms here would itself leak them.
# Reviewed exceptions (home-path rule only, nothing else on those lines):
#   - flake.nix: a `url = "git+file:///…/<sibling>…";` line ending in the
#     expected marker (temporary input URLs; each carries a TODO to remove it
#     once the input is published);
#   - flake.lock: a `"url": "(git+)file:///…/<sibling>"` line of a sibling;
#   - checks/leaks/expected.txt: exact recorded hits, see below.
# (expected.txt itself holds the matched text and is not scanned.)
# The marker anywhere but the root flake.nix is itself a hit.
dir=$1
hits=$(mktemp)
cd "$dir" || exit 2
base=(--no-heading --with-filename --line-number --hidden --no-ignore
  --glob '!checks/leaks/fixtures/**' --glob '!checks/leaks/expected.txt' --glob '!.git/**')
only=(--only-matching)
siblings='(ai-sandbox|pi-setup)'

# tag <rule>: turn `path:line:match` into `path:line:[rule] match`
tag() { sed -E "s/^([^:]+:[0-9]+:)/\\1[$1] /"; }

# e-mail addresses, minus the reserved example domains (example.com, .org,
# .net, .invalid and any name under the RFC 2606 `.example` top-level domain)
# and the SSH remote form
rg "${base[@]}" "${only[@]}" -P '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' . |
  grep -v -E '@example\.(com|org|net|invalid)$|\.example$|:git@github\.com$' | tag email >>"$hits" || true

# key ids in key context (16-40 hex), and 0x-prefixed ids (8-40 hex)
rg "${base[@]}" "${only[@]}" -P -i '(signing_?key|user\.signingkey|--local-user|--default-key|\s-u)\s*[=: ]\s*"?[0-9a-f]{16,40}\b' . | tag key-id >>"$hits" || true
rg "${base[@]}" "${only[@]}" -P -i '\b0x[0-9a-f]{8,40}\b' . | tag hex-id >>"$hits" || true

# personal home directories, minus the reviewed sibling-input URL lines
exempt=$(mktemp)
{
  rg "${base[@]}" "${only[@]}" -P '^\s*url = "git\+file:///[^" ]*/'"$siblings"'(\?[^" ]*)?";\s*# leak-scan: expected$' flake.nix 2>/dev/null
  rg "${base[@]}" "${only[@]}" -P '^\s*"url": "(git\+)?file:///[^" ]*/'"$siblings"'(\?[^" ]*)?"$' flake.lock 2>/dev/null
} | sed -E 's/^(\.\/)?([^:]+:[0-9]+:).*/.\/\2/' >"$exempt" || true
rg "${base[@]}" "${only[@]}" -P '/(home|Users)/(?!coder\b|tester\b|ai-test\b|u\b)[A-Za-z_][A-Za-z0-9_-]*' . |
  awk -v ex="$exempt" 'BEGIN { while ((getline l < ex) > 0) e[l]=1 } { match($0, /^[^:]+:[0-9]+:/); if (!(substr($0, 1, RLENGTH) in e)) print }' |
  tag home-path >>"$hits" || true

# the exception marker is only honoured in the root flake.nix
rg "${base[@]}" "${only[@]}" --glob '!/flake.nix' -P '#\s*leak-scan: expected\s*$' . | tag marker >>"$hits" || true

# git+ssh remotes
rg "${base[@]}" "${only[@]}" -P 'git\+ssh://' . | tag git-ssh >>"$hits" || true

# single-label hostnames in URLs (http://<host>:<port>), other than localhost
rg "${base[@]}" "${only[@]}" -P 'https?://(?!localhost(?![A-Za-z0-9.-]))[A-Za-z0-9-]+(?![A-Za-z0-9.-])' . | tag single-label-url >>"$hits" || true

# RFC 1918 private addresses
rg "${base[@]}" "${only[@]}" -P '(?<![0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})(?![0-9])' . | tag rfc1918 >>"$hits" || true

# Reviewed exceptions in content that must stay byte-identical (skills): one
# exact hit per line in checks/leaks/expected.txt, `path:line:[rule] match`
# (`#` comments allowed). It exempts only that match, nothing else on the
# line. A listed entry that no longer hits is stale and fails the scan.
sort -u "$hits" >"$hits.s"
if [ -f checks/leaks/expected.txt ]; then
  pats=$(mktemp)
  while IFS= read -r entry; do
    case $entry in '' | '#'*) continue ;; esac
    if grep -q -x -F -e "./$entry" "$hits.s"; then
      echo "./$entry" >>"$pats"
    else
      echo "checks/leaks/expected.txt: stale entry $entry" >>"$hits.s"
    fi
  done <checks/leaks/expected.txt
  if [ -s "$pats" ]; then
    grep -v -x -F -f "$pats" "$hits.s" >"$hits" || true
  else
    cp "$hits.s" "$hits"
  fi
else
  cp "$hits.s" "$hits"
fi

if [ -s "$hits" ]; then
  sort -u "$hits" >&2
  exit 1
fi
