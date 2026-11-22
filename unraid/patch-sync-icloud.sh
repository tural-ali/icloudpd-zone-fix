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
# flag_incomplete_download: also accepts the line icloudpd ends with after
# --ignore-indexing-state ("All photos and videos that iCloud listed have been
# downloaded, but the listing may be incomplete: ..."), which the indexing
# fallback (unraid/icloudpd-indexing-fallback.sh) leads to. Without this, every
# such run that downloaded what iCloud listed would be reported as failed.
#
# Fails the build if upstream renames any of these functions, changes the body
# of resolve_library_list, or rewords the check in flag_incomplete_download, so
# a change can never silently disappear from, or silently override, a weekly
# rebuild.
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

old='All (photos and videos|photos|videos) have been downloaded'
new='All (photos and videos|photos|videos) (that iCloud listed )?have been downloaded'
awk -v old="$old" -v new="$new" '
  /^flag_incomplete_download\(\)/ { f = 1 }
  f && (i = index($0, old)) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); n++ }
  f && /^}/ { f = 0 }
  { print }
  END { if (n != 1) exit 1 }
' "$f" > "$f.new" || { rm -f "$f.new"; echo "patch-sync-icloud: the check in flag_incomplete_download() changed or is missing in $f" >&2; exit 1; }
cat "$f.new" > "$f"
rm -f "$f.new"
echo "patch-sync-icloud: flag_incomplete_download accepts a run that downloaded what iCloud listed"
