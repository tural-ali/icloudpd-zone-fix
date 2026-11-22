#!/bin/ash
# Runs the patched resolve_library_list() from sync-icloud.sh against canned
# `icloudpd --list-libraries` results. Usage: test-resolve-library-list.sh [patched sync-icloud.sh]
# Runs during the image build (Dockerfile.unraid), so a regression fails the build.
set -u
script="${1:-/usr/local/bin/sync-icloud.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sandbox="$work/t/icloudpd"
fails=0

# The function plus the log helpers it calls, with its fixed /tmp/icloudpd
# paths pointed at the sandbox and icloudpd itself replaced by a fake.
for fn in log_error log_debug resolve_library_list; do
  awk -v fn="$fn" '$0 ~ "^" fn "\\(\\)" { f = 1 } f { print } f && /^}/ { exit }' "$script"
done | sed -e "s#/tmp/icloudpd/#$sandbox/#g" -e "s#/opt/icloudpd/bin/icloudpd #$work/icloudpd #g" > "$work/fn.sh"
grep -q "Could not list photo libraries" "$work/fn.sh" || { echo "FAIL: $script is not patched"; exit 1; }

# run_as normally does `su user -s /bin/ash -c CMD`; here it just runs CMD.
echo 'run_as() { ash -c "$1"; }' > "$work/stub.sh"

# Fake `icloudpd --list-libraries`: prints what the real one printed in each
# scenario (log lines on stdout and stderr) and exits with its code.
cat > "$work/icloudpd" <<'EOF'
#!/bin/ash
# Since 1.34 icloudpd logs to stdout and defaults to DEBUG, which dumps the
# failed request over several lines; at INFO only dated single lines remain.
debug=1
case " $* " in *" --log-level info "*) debug=0;; esac
dump() {
  [ "$debug" = 1 ] || return 0
  printf '2026-11-22 08:18:39 DEBUG    {\n  "request": {\n    "method": "POST"\n  }\n}\n'
}
case "$SCENARIO" in
  ok)       printf 'PrimarySync1\nSharedSync-00000000-1111-2222-3333-444444444444\n'; exit 0;;
  header)   printf 'Libraries:\nPrimarySync1\n'; exit 0;;
  indexing) printf '2026-11-17 00:30:16 INFO     Processing user: someone@example.com\n' >&2
            printf '2026-11-17 00:30:17 DEBUG    {\n  "request": {\n    "method": "POST"\n  }\n}\n'
            printf '2026-11-17 00:30:17 INFO     Apple iCloud Photo Library has not finished indexing yet\n' >&2
            exit 1;;
  junk_rc0) printf '  "request": {\n'; exit 0;;
  # what the indexing fallback prints: the failed first run, its warning, then the retry
  fallback) printf '2026-11-22 08:17:35 INFO     Processing user: someone@example.com\n'
            printf '2026-11-22 08:18:39 INFO     Apple iCloud Photo Library has not finished indexing yet\n'; dump
            printf '2026-11-22 08:18:39 WARNING  iCloud still reports the library as indexing; running again with --ignore-indexing-state\n'
            printf '2026-11-22 08:19:42 WARNING  Library PrimarySync1 is still reported as indexing (RUNNING on all 15 checks)\n'
            printf 'PrimarySync1\nSharedSync-00000000-1111-2222-3333-444444444444\n'; exit 0;;
  empty)    exit 0;;
  *)        echo "unknown scenario $SCENARIO" >&2; exit 2;;
esac
EOF
chmod +x "$work/icloudpd"

# run SCENARIO EXPECTED_STDOUT EXPECTED_RC EXPECTED_ERROR_TEXT [SKIP_LIBRARY]
# EXPECTED_ERROR_TEXT "" means the check/download error files must stay empty.
run() {
  scenario="$1" want_out="$2" want_rc="$3" want_err="$4" skip="${5:-}"
  rm -rf "$work/t"; mkdir -p "$sandbox"
  out="$(SCENARIO="$scenario" SKIP="$skip" ash -c '
    . "$0"; . "$1"
    OLDIFS="$IFS"; debug_logging=false; photo_library="all libraries"; skip_library="$SKIP"
    apple_id=a; auth_domain=com
    resolve_library_list; echo "rc=$?"
  ' "$work/stub.sh" "$work/fn.sh" 2>/dev/null)"
  got_rc="${out##*rc=}"; got_out="${out%rc=*}"; got_out="${got_out%"
"}"
  errs="$(cat "$sandbox/icloudpd_check_error" "$sandbox/icloudpd_download_error" 2>/dev/null)"
  ok=1
  [ "$got_out" = "$want_out" ] || ok=0
  [ "$got_rc" = "$want_rc" ] || ok=0
  if [ -n "$want_err" ]; then
    case "$errs" in *"$want_err"*) ;; *) ok=0;; esac
    [ "$(cat "$sandbox/icloudpd_download_exit_code" 2>/dev/null)" = 1 ] || ok=0
  else
    [ -z "$errs" ] || ok=0
  fi
  if [ "$ok" = 1 ]; then echo "ok   $scenario${skip:+ (skip $skip)}"; else
    echo "FAIL $scenario: out=[$got_out] rc=[$got_rc] errors=[$errs]"; fails=$((fails + 1)); fi
}

run ok       "PrimarySync1,SharedSync-00000000-1111-2222-3333-444444444444" 0 ""
run ok       "SharedSync-00000000-1111-2222-3333-444444444444" 0 "" PrimarySync1
run header   "PrimarySync1" 0 ""
run fallback "PrimarySync1,SharedSync-00000000-1111-2222-3333-444444444444" 0 ""
run junk_rc0 "" 1 "printed something that is not a library name"
run empty    "" 1 "returned no libraries"
run indexing "" 1 "exited with code 1: Apple iCloud Photo Library has not finished indexing yet"
# The "Processing user" line carries the Apple ID; it must not reach notifications.
case "$errs" in *"@"*) echo "FAIL indexing: Apple ID leaked into the error"; fails=$((fails + 1));; esac

if [ "$fails" = 0 ]; then echo "resolve_library_list: all tests passed"; else
  echo "resolve_library_list: $fails failed"; exit 1; fi
