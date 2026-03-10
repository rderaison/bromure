echo "profile: DISPLAY=$DISPLAY tty=$(tty)" > /dev/hvc0 2>/dev/null
if [ -z "$DISPLAY" ]; then
  echo "starting X..." > /dev/hvc0 2>/dev/null
  startx > /tmp/startx.log 2>&1
  echo "startx exited: $?" > /dev/hvc0 2>/dev/null
  cat /tmp/startx.log > /dev/hvc0 2>/dev/null
  doas poweroff
fi
