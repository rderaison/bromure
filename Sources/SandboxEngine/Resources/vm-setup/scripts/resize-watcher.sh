#!/bin/sh
# Follows the VZ-advertised preferred mode (the host window's size) and,
# when the host asks for it, runs the guest display at a higher refresh
# rate than the 60 Hz virtio-gpu advertises.
#
# DISPLAY_HZ (from /tmp/bromure/chrome-env, written at claim time by the
# host via chromeEnvExtra) is the host screen's refresh rate — 120 on
# ProMotion Macs. virtio-gpu accepts any modeline we hand it (measured:
# Chromium's rAF cadence goes 60 → 118 Hz right after the switch), so for
# each preferred WxH we synthesise a "WxH_120.00" mode with gtf, add it
# once, and select it instead of the 60 Hz preferred mode. The current
# mode is compared by geometry only, so the custom mode never fights the
# preferred one; a window resize changes WxH and re-runs the whole thing.
OUTPUT=$(xrandr 2>/dev/null | grep " connected" | cut -d" " -f1 | head -1)
if [ -z "$OUTPUT" ]; then OUTPUT="Virtual-1"; fi
ENV=/tmp/bromure/chrome-env
ADDED=""
while true; do
  CUR=$(xrandr 2>/dev/null | grep "^$OUTPUT " | grep -o "[0-9]*x[0-9]*+[0-9]*+[0-9]*" | head -1 | cut -d+ -f1)
  BEST=$(xrandr 2>/dev/null | grep -A1 "^$OUTPUT " | tail -1 | sed "s/^ *//" | cut -d" " -f1)
  HZ=60
  if [ -r "$ENV" ]; then
    HZ=$(sh -c ". $ENV 2>/dev/null; echo \${DISPLAY_HZ:-60}")
  fi
  case "$HZ" in ''|*[!0-9]*) HZ=60 ;; esac
  if [ -n "$BEST" ] && [ "$BEST" != "$CUR" ]; then
    MODE="$BEST"
    if [ "$HZ" -gt 60 ] && command -v gtf >/dev/null 2>&1; then
      W=${BEST%x*}; H=${BEST#*x}
      NAME="${BEST}_${HZ}.00"
      case " $ADDED " in
        *" $NAME "*) ;;
        *)
          ML=$(gtf "$W" "$H" "$HZ" 2>/dev/null | grep Modeline | sed 's/^ *Modeline *//; s/"//g')
          if [ -n "$ML" ]; then
            # shellcheck disable=SC2086
            xrandr --newmode $ML >/dev/null 2>&1
            xrandr --addmode "$OUTPUT" "$NAME" >/dev/null 2>&1 && ADDED="$ADDED $NAME"
          fi
          ;;
      esac
      case " $ADDED " in *" $NAME "*) MODE="$NAME" ;; esac
    fi
    xrandr --output "$OUTPUT" --mode "$MODE" 2>/dev/null \
      || xrandr --output "$OUTPUT" --mode "$BEST" 2>/dev/null
  fi
  sleep 1
done
