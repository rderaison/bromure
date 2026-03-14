clear
if [ -z "$DISPLAY" ]; then
  startx > /tmp/startx.log 2>&1
  doas poweroff
fi
