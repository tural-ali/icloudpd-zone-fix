#!/bin/sh
# Build-time patch for boredazfcuk's sync-icloud.sh.
#
# reauth_url: when a container's icloudpd.conf sets it, the re-authentication hint
# in cookie-expiry and failure notifications becomes that link instead of
# "To re-authenticate now, run: docker exec -it <container name> reauth.sh".
# Unset, the upstream wording is unchanged.
#
# Fails the build if upstream renames the function, so the change can never
# silently disappear from a weekly rebuild.
set -eu
f="${1:-/usr/local/bin/sync-icloud.sh}"
awk '
  { print }
  /^reauth_instructions\(\)[[:space:]]*$/ { armed = 1; next }
  armed && /^\{[[:space:]]*$/ {
    print "   if [ -n \"${reauth_url}\" ]; then echo \"Re-authenticate: ${reauth_url}\"; return; fi"
    armed = 0; patched = 1
  }
  END { if (!patched) exit 1 }
' "$f" > "$f.new" || { rm -f "$f.new"; echo "patch-sync-icloud: reauth_instructions() not found in $f" >&2; exit 1; }
cat "$f.new" > "$f"
rm -f "$f.new"
echo "patch-sync-icloud: reauth_url support added"
