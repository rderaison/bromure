#!/bin/sh
OUTPUT=$(xrandr 2>/dev/null | grep " connected" | cut -d" " -f1 | head -1)
if [ -z "$OUTPUT" ]; then OUTPUT="Virtual-1"; fi
LAST=""
while true; do
  CUR=$(xrandr 2>/dev/null | grep "^$OUTPUT " | grep -o "[0-9]*x[0-9]*+[0-9]*+[0-9]*" | head -1 | cut -d+ -f1)
  BEST=$(xrandr 2>/dev/null | grep -A1 "^$OUTPUT " | tail -1 | sed "s/^ *//" | cut -d" " -f1)
  if [ -n "$BEST" ] && [ "$BEST" != "$CUR" ]; then
    xrandr --output "$OUTPUT" --mode "$BEST" 2>/dev/null
    LAST="$BEST"
  fi
  sleep 1
done
