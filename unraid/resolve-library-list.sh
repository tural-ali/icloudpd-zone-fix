resolve_library_list()
{
   # Replaced at build time by icloudpd-zone-fix (unraid/patch-sync-icloud.sh).
   # Upstream took every line `icloudpd --list-libraries` printed as a library
   # name and ignored its exit code, so when Apple refused the listing (for
   # example "Apple iCloud Photo Library has not finished indexing yet") the
   # debug dump became the library list and the real reason was lost.
   # Here a failed or malformed listing returns no libraries and reports the
   # reason through the files that check_files and the download step already
   # read, so it reaches the log and the failure notification.
   # icloudpd logs to stdout since 1.34 and defaults to DEBUG, whose
   # multi-line request dumps would land among the names, so it runs at INFO;
   # its single-line log lines all start with the date and are dropped.
   local all_libraries resolved_list list_exit_code reason messages
   if [ "${photo_library}" = "all libraries" ]
   then
      log_debug "Fetching libraries list..." >&2
      run_as "/opt/icloudpd/bin/icloudpd --username ${apple_id} --cookie-directory /config --domain ${auth_domain} --directory /dev/null --log-level info --list-libraries >/tmp/icloudpd/icloudpd_libraries 2>/tmp/icloudpd/icloudpd_libraries_error; echo \$? >/tmp/icloudpd/icloudpd_libraries_exit_code"
      list_exit_code="$(cat /tmp/icloudpd/icloudpd_libraries_exit_code 2>/dev/null)"
      all_libraries="$(sed -e '/^[0-9]/d' -e '/^Libraries:$/d' /tmp/icloudpd/icloudpd_libraries 2>/dev/null)"
      reason=""
      if [ "${list_exit_code}" != "0" ]
      then
         reason="icloudpd --list-libraries exited with code ${list_exit_code:-unknown}"
      elif [ -z "${all_libraries}" ]
      then
         reason="icloudpd --list-libraries returned no libraries"
      elif printf '%s\n' "${all_libraries}" | grep -qvE '^[A-Za-z0-9][A-Za-z0-9_-]*$'
      then
         reason="icloudpd --list-libraries printed something that is not a library name"
      fi
      if [ -n "${reason}" ]
      then
         # icloudpd's own log lines carry the cause; keep the last few.
         messages="$(cat /tmp/icloudpd/icloudpd_libraries /tmp/icloudpd/icloudpd_libraries_error 2>/dev/null \
            | sed -n -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} +(INFO|WARNING|ERROR|CRITICAL) +//p' \
            | grep -vE '^(Processing user|Authenticating|Authentication completed)' | tail -n 3 | tr '\n' ' ')"
         if [ -n "${messages}" ]
         then
            reason="${reason}: ${messages% }"
         fi
         log_error "Could not list photo libraries: ${reason}" >&2
         echo "Could not list photo libraries: ${reason}" >>/tmp/icloudpd/icloudpd_check_error
         echo "Could not list photo libraries: ${reason}" >/tmp/icloudpd/icloudpd_download_error
         echo 1 >/tmp/icloudpd/icloudpd_download_exit_code
         return 1
      fi
      log_debug "Building list of libraries..." >&2
      IFS=$'\n'
      for library in ${all_libraries}
      do
         if [ -n "${skip_library}" ] && [ "${skip_library}" = "${library}" ]
         then
            continue
         fi
         log_debug " - ${library}" >&2
         if [ -z "${resolved_list}" ]
         then
            resolved_list="${library}"
         else
            resolved_list="${resolved_list},${library}"
         fi
      done
      IFS="${OLDIFS}"
   else
      resolved_list="${photo_library}"
   fi
   echo "${resolved_list}"
}
