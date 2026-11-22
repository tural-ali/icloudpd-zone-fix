#!/bin/ash
# Tests unraid/icloudpd-indexing-fallback.sh against a fake icloudpd, and the
# patched flag_incomplete_download() from sync-icloud.sh against canned logs.
# Usage: test-indexing-fallback.sh WRAPPER [patched sync-icloud.sh]
# Runs during the image build (Dockerfile.unraid), so a regression fails the build.
set -u
wrapper="$1"
script="${2:-/usr/local/bin/sync-icloud.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0

# Fake icloudpd: appends its arguments (one per line, then "--") to calls.log,
# then prints and exits as the real one did in each scenario. A run counts as
# "indexing" when SCENARIO says so for that call number (1-based).
cat > "$work/icloudpd" <<'EOF'
#!/bin/ash
n=$(( $(grep -c '^--$' "$WORK/calls.log" 2>/dev/null || echo 0) + 1 ))
for a do echo "$a"; done >> "$WORK/calls.log"
echo -- >> "$WORK/calls.log"
indexing() {
  printf '2026-11-22 08:00:00 INFO     Apple iCloud Photo Library has not finished indexing yet\n'
  exit 1
}
case "$SCENARIO:$n" in
  ok:1)              printf 'downloading\n2026-11-22 08:00:01 INFO     All photos and videos have been downloaded\n'; exit 0;;
  other_error:1)     printf '2026-11-22 08:00:00 ERROR    Something else went wrong\n'; printf 'Traceback\n' >&2; exit 1;;
  stuck:*)           indexing;;
  recovers:1)        indexing;;
  recovers:2)        printf '2026-11-22 08:00:05 WARNING  All photos and videos that iCloud listed have been downloaded, but the listing may be incomplete\n'; exit 0;;
  flaky:1|flaky:2)   indexing;;
  flaky:3)           printf '2026-11-22 08:00:05 WARNING  All photos and videos that iCloud listed have been downloaded, but the listing may be incomplete\n'; exit 0;;
  listing_short:1)   indexing;;
  listing_short:2)   printf '2026-11-22 08:00:05 ERROR    iCloud listed only 10 of 3064 items in the library\n'; exit 1;;
  stderr_only:1)     printf 'Apple iCloud Photo Library has not finished indexing yet\n' >&2; exit 1;;
  *)                 echo "fake icloudpd: unexpected call $n in scenario $SCENARIO" >&2; exit 99;;
esac
EOF
chmod +x "$work/icloudpd"

# run NAME SCENARIO EXPECTED_RC EXPECTED_CALLS EXPECTED_SECOND_ARGS ARGS...
# EXPECTED_SECOND_ARGS is the second call's arguments joined with spaces ("" if none).
run() {
  name="$1" scenario="$2" want_rc="$3" want_calls="$4" want_second="$5"
  shift 5
  rm -f "$work/calls.log"
  WORK="$work" SCENARIO="$scenario" ICLOUDPD_REAL="$work/icloudpd" \
    ash "$wrapper" "$@" >"$work/stdout" 2>"$work/stderr"
  got_rc=$?
  got_calls="$(grep -c '^--$' "$work/calls.log" 2>/dev/null)"
  got_second="$(awk 'c == 1 && $0 != "--" { printf "%s%s", sep, $0; sep = " " } $0 == "--" { c++ }' "$work/calls.log" 2>/dev/null)"
  ok=1
  [ "$got_rc" = "$want_rc" ] || ok=0
  [ "$got_calls" = "$want_calls" ] || ok=0
  [ "$got_second" = "$want_second" ] || ok=0
  if [ "$ok" = 1 ]; then echo "ok   $name"; else
    echo "FAIL $name: rc=[$got_rc] calls=[$got_calls] second=[$got_second]"; fails=$((fails + 1)); fi
}
expect_out() {
  name="$1" stream="$2" text="$3"
  if grep -qF -- "$text" "$work/$stream"; then echo "ok   $name"; else
    echo "FAIL $name: [$text] missing from $stream:"; sed 's/^/    /' "$work/$stream"; fails=$((fails + 1)); fi
}

full="--directory /data --username a --auto-delete --keep-icloud-recent-days 30 --folder-structure x/{:%Y} --library PrimarySync1"

run "a normal run is passed through once" ok 0 1 "" $full
expect_out "its output reaches stdout" stdout "All photos and videos have been downloaded"
run "another failure is returned as is" other_error 1 1 "" $full
expect_out "its stderr is untouched" stderr "Traceback"
run "indexing: retried without deleting options" recovers 0 2 \
  "--directory /data --username a --folder-structure x/{:%Y} --library PrimarySync1 --ignore-indexing-state" $full
expect_out "the first run's output is still shown" stdout "has not finished indexing yet"
expect_out "the retry is announced as a warning" stdout "WARNING  iCloud still reports the library as indexing; running again with --ignore-indexing-state and without --auto-delete --keep-icloud-recent-days 30, so nothing is deleted this run"
run "every deleting spelling is dropped" recovers 0 2 "--username a --library L --ignore-indexing-state" \
  --username a --delete-after-download --keep-icloud-recent-days=7 --prune-orphans --prune-orphans-adopt-existing --library L
run "an argument with spaces survives the retry" recovers 0 2 "--username a --folder-structure a b --ignore-indexing-state" \
  --username a --folder-structure "a b"
[ "$(sed -n 4p "$work/calls.log")" = "a b" ] && echo "ok   ...as one argument" || { echo "FAIL ...as one argument"; fails=$((fails + 1)); }
run "list-libraries is retried too" recovers 0 2 "--username a --list-libraries --ignore-indexing-state" --username a --list-libraries
expect_out "nothing dropped, nothing claimed" stdout "running again with --ignore-indexing-state"
if grep -qF "nothing is deleted" "$work/stdout"; then echo "FAIL no 'nothing is deleted' without dropped options"; fails=$((fails + 1)); else echo "ok   no 'nothing is deleted' without dropped options"; fi
run "a refused retry is repeated until it gets through" flaky 0 3 "--username a --ignore-indexing-state" --username a --auto-delete
expect_out "the repeat is announced" stdout "WARNING  iCloud did not answer RUNNING to every indexing check; trying again (2/4)"
run "still indexing: 4 retries, then fails" stuck 1 5 "--username a --ignore-indexing-state" --username a --auto-delete
run "a short listing on the retry fails" listing_short 1 2 "--username a --ignore-indexing-state" --username a
run "already opted in: no retry" stuck 1 1 "" --username a --ignore-indexing-state
run "auth-only is never wrapped" stuck 1 1 "" --username a --auth-only
run "only stdout is matched" stderr_only 1 1 "" --username a

# flag_incomplete_download, with its fixed paths pointed at a sandbox
sandbox="$work/t"
awk '/^flag_incomplete_download\(\)/ { f = 1 } f { print } f && /^}/ { exit }' "$script" \
  | sed "s#/tmp/icloudpd/#$sandbox/#g" > "$work/flag.sh"
grep -q "that iCloud listed" "$work/flag.sh" || { echo "FAIL: flag_incomplete_download in $script is not patched"; fails=$((fails + 1)); }
# flag NAME LOG EXPECTED_EXIT_CODE_AFTER
flag() {
  name="$1" log="$2" want="$3"
  rm -rf "$sandbox"; mkdir -p "$sandbox"
  printf 'earlier library\n%s\n' "$log" > "$sandbox/icloudpd_sync.log"
  echo 0 > "$sandbox/icloudpd_download_exit_code"
  ash -c '. "$0"; flag_incomplete_download 2' "$work/flag.sh"
  got="$(cat "$sandbox/icloudpd_download_exit_code")"
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: exit code file=[$got]"; fails=$((fails + 1)); fi
}
flag "a complete run passes" "2026-11-22 08:00:01 INFO     All photos and videos have been downloaded" 0
flag "the videos variant passes" "2026-11-22 08:00:01 INFO     All videos have been downloaded" 0
flag "an incomplete-listing run passes" "2026-11-22 08:00:05 WARNING  All photos and videos that iCloud listed have been downloaded, but the listing may be incomplete" 0
flag "a run without the end line fails" "2026-11-22 08:00:00 INFO     Apple iCloud Photo Library has not finished indexing yet" 1

if [ "$fails" = 0 ]; then echo "indexing fallback: all tests passed"; else
  echo "indexing fallback: $fails failed"; exit 1; fi
