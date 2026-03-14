#!/bin/sh
# download-guard.sh — Prevent file downloads inside the guest VM.
#
# Uses inotifywait to watch /home/chrome/Downloads for new files.
# Any file created there is immediately deleted to prevent the user
# from saving files to the VM.
#
# Only watches ~/Downloads (Chromium's download directory).  Files
# transferred via the host file picker land in /home/chrome/ directly
# and must NOT be deleted.
#
# Started by config-agent.py when blockDownloads is enabled.

WATCH_DIR="/home/chrome/Downloads"

# Ensure the directory exists (Chromium creates it on first download,
# but inotifywait needs it at startup).
mkdir -p "$WATCH_DIR"

exec inotifywait -m -r -q \
    -e create -e moved_to \
    --format '%w%f' \
    "$WATCH_DIR" 2>/dev/null | while read -r filepath; do
    [ -f "$filepath" ] && rm -f "$filepath" 2>/dev/null
done
