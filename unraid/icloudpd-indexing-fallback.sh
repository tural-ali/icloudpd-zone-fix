#!/bin/ash
# Installed as /opt/icloudpd/bin/icloudpd by Dockerfile.unraid; the real entry
# point is moved to icloudpd.real next to it.
#
# Since 2026-11-17 iCloud keeps answering "RUNNING" to the indexing check of
# some libraries that list and download normally (#1387), so every run ends
# with "Apple iCloud Photo Library has not finished indexing yet" and nothing
# is downloaded for days. icloudpd's --ignore-indexing-state gets past that,
# but it refuses options that delete, so it can't simply be added to every run.
#
# This runs icloudpd unchanged. Only when that run fails on the indexing check
# does it run once more with --ignore-indexing-state and without the options
# that delete (--auto-delete, --delete-after-download, --keep-icloud-recent-days,
# --prune-orphans), so new photos still arrive and nothing is deleted from an
# incomplete listing. When iCloud reports FINISHED again, the first run
# succeeds and deleting resumes by itself.
#
# stdout passes through as it is written and stderr is untouched, so callers
# that tee or redirect either stream see the same thing as without this wrapper.
real="${ICLOUDPD_REAL:-/opt/icloudpd/bin/icloudpd.real}"
indexing_message="Apple iCloud Photo Library has not finished indexing yet"

for arg do
  case "$arg" in
    # already opted in, or interactive (sign-in prompts must not be piped)
    --ignore-indexing-state|--auth-only|--help|-h|--version) exec "$real" "$@";;
  esac
done

work="$(mktemp -d)" || exec "$real" "$@"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

{ "$real" "$@"; echo $? >"$work/rc"; } | tee "$work/out"
rc="$(cat "$work/rc" 2>/dev/null)"
rc="${rc:-1}"
if [ "$rc" -eq 0 ] || ! grep -qF "$indexing_message" "$work/out"; then
  exit "$rc"
fi

dropped=""
skip_value=0
for arg do
  shift
  if [ "$skip_value" -eq 1 ]; then
    skip_value=0
    dropped="$dropped $arg"
    continue
  fi
  case "$arg" in
    --auto-delete|--delete-after-download|--prune-orphans|--prune-orphans-adopt-existing|--keep-icloud-recent-days=*)
      dropped="$dropped $arg"
      continue;;
    --keep-icloud-recent-days)
      skip_value=1
      dropped="$dropped $arg"
      continue;;
  esac
  set -- "$@" "$arg"
done

# same layout as icloudpd's own log lines, which sync-icloud.sh parses
message="iCloud still reports the library as indexing; running again with --ignore-indexing-state"
if [ -n "$dropped" ]; then
  message="$message and without$dropped, so nothing is deleted this run"
fi
printf '%s WARNING  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message"
"$real" "$@" --ignore-indexing-state
