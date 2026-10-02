clear
if [ -z "$DISPLAY" ]; then
  if grep -Fqw 'bromure.experimental_multigpu=2' /proc/cmdline; then
    if [ -r /run/bromure-multigpu/xorg.conf ]; then
      startx /usr/local/bin/experimental-multigpu.py session -- \
        -config /run/bromure-multigpu/xorg.conf > /tmp/startx.log 2>&1
    else
      echo 'Experimental multi-GPU preparation failed; see /tmp/bromure/multigpu-prepare.log' > /tmp/startx.log
    fi
    # The experimental host owns VM lifetime. Keep the failed session's logs
    # and root diagnostic channel available until its final window closes.
    echo 'BROMURE_MULTIGPU_XORG_STOPPED: logs retained in /tmp/startx.log' > /dev/hvc0
    sleep infinity
  else
    startx > /tmp/startx.log 2>&1
  fi
  doas poweroff
  sleep infinity
fi
