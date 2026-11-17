#!/bin/sh
# Build-time patch for boredazfcuk's sync-icloud.sh.
#
# reauth_url: when a container's icloudpd.conf sets it, the re-authentication hint
# in cookie-expiry and failure notifications becomes that link instead of
# "To re-authenticate now, run: docker exec -it <container name> reauth.sh".
# Unset, the upstream wording is unchanged.
#
# resolve_library_list: replaced with unraid/resolve-library-list.sh, which
# checks the exit code and output of `icloudpd --list-libraries` instead of
# treating every printed line as a library name (see that file).
#
# Fails the build if upstream renames either function, or changes the body of
# resolve_library_list, so a change can never silently disappear from, or
# silently override, a weekly rebuild.
set -eu
f="${1:-/usr/local/bin/sync-icloud.sh}"
here="$(dirname "$0")"

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

# sha256 of the upstream function this replacement was written against. When
# upstream changes it, review the new version, port anything new into
# resolve-library-list.sh and update this hash.
expected=1aa11f7b3496bf57e545152c1ddd02d21c304d18588c2e69c108d107b36feb98
actual="$(awk '/^resolve_library_list\(\)/ { f = 1 } f { print } f && /^}/ { exit }' "$f" | sha256sum | cut -d' ' -f1)"
if [ "$actual" != "$expected" ]; then
  echo "patch-sync-icloud: upstream resolve_library_list() changed or is missing (sha256 $actual); review unraid/resolve-library-list.sh" >&2
  exit 1
fi
awk -v repl="$here/resolve-library-list.sh" '
  /^resolve_library_list\(\)/ { skip = 1; while ((getline line < repl) > 0) print line; replaced = 1; next }
  skip { if (/^}/) skip = 0; next }
  { print }
  END { if (!replaced) exit 1 }
' "$f" > "$f.new" || { rm -f "$f.new"; echo "patch-sync-icloud: resolve_library_list() not replaced in $f" >&2; exit 1; }
cat "$f.new" > "$f"
rm -f "$f.new"
echo "patch-sync-icloud: resolve_library_list checks the library listing"
