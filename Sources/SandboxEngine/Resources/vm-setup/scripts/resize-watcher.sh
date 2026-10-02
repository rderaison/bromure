#!/bin/sh
# Keep the existing xinitrc entry point; Python subscribes to RandR events.
exec /usr/bin/python3 /usr/local/bin/resize-watcher.py
