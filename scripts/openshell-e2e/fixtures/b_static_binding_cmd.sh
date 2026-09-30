
http_request() {
  local host="$1" path="$2" status_line line
  HTTP_STATUS= HTTP_BODY=
  if ! exec 3<>"/dev/tcp/$host/@@PORT@@"; then
    HTTP_STATUS=connect-denied
    return 1
  fi
  printf 'GET %s HTTP/1.1\r\nHost: %s:@@PORT@@\r\nAuthorization: Bearer %s\r\nConnection: close\r\n\r\n' "$path" "$host" "$BOUND_TOKEN_A" >&3
  IFS= read -r status_line <&3 || return 1
  status_line="${status_line%$'\r'}"
  HTTP_STATUS="${status_line#* }"
  HTTP_STATUS="${HTTP_STATUS%% *}"
  while IFS= read -r line <&3; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && break
  done
  while IFS= read -r line <&3 || [[ -n "$line" ]]; do HTTP_BODY+="$line"; done
  exec 3>&- 3<&-
}
http_request host.openshell.internal /allowed/check; allowed="$HTTP_BODY"
http_request host.docker.internal /allowed/check || true; host_denied="$HTTP_STATUS"
http_request host.openshell.internal /other/check; path_denied="$HTTP_STATUS"
printf 'ALLOWED=%s HOST_DENIED=%s PATH_DENIED=%s\n' "$allowed" "$host_denied" "$path_denied"
