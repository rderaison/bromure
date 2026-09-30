set -eu
exec 3<>/dev/tcp/host.openshell.internal/@@PORT@@
printf 'GET / HTTP/1.1\r\nHost: host.openshell.internal:@@PORT@@\r\n\r\n' >&3
while true; do
  line=
  if IFS= read -r -t 5 line <&3; then
    printf '%s\n' "$line"
  else
    status=$?
    [ "$status" -eq 1 ] || { echo EOF_TIMEOUT; exit 1; }
    [ -z "$line" ] || printf '%s\n' "$line"
    break
  fi
done
printf 'RESPONSE_EOF\n'
