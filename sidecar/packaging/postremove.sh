#!/bin/sh
# Runs after remove/erase and after the remove half of an upgrade, for both
# .deb and .rpm.
#
# IT NEVER TOUCHES USER DATA. `~/.local/share/BromureSidecar` holds the SSH
# host key, the device record that identifies this machine in the account,
# sessions.json and the logs. Deleting it would silently un-enrol every user
# on the box, and reinstalling would come back as a different machine needing
# re-admission in Bromure AC's fleet dialog. That is true on `dpkg --purge`
# too: a system package has no business reaching into home directories, and
# there may be several.
#
# It also does not stop anybody's daemon: root cannot reach another user's
# systemd manager, and a running daemon holds its own (now unlinked) binary
# inode, so it keeps working until its owner stops it.
set -e

removing=0
case "${1:-}" in
    remove|purge) removing=1 ;;   # dpkg
    0)            removing=1 ;;   # rpm: 0 = last copy erased
esac

# Upgrades run this with "upgrade"/"1": say nothing, the postinstall speaks.
[ "$removing" = 1 ] || exit 0

cat <<'EOF'
Bromure Sidecar removed.

Anyone still running it keeps running until they stop it. The unit file is
already gone, so `disable` will not work -- stop it and clear the leftover
link by hand:

    systemctl --user stop bromure-sidecar
    rm -f ~/.config/systemd/user/default.target.wants/bromure-sidecar.service
    systemctl --user daemon-reload

(Next time, `systemctl --user disable --now bromure-sidecar` BEFORE removing
the package does all of that cleanly.)

Your data was NOT removed -- the host key, the machine's identity in your
account, sessions and logs are still in:

    ~/.local/share/BromureSidecar

Reinstalling returns to the same machine identity. Delete that directory
yourself if you want this machine forgotten, and turn off lingering if you
enabled it:

    sudo loginctl disable-linger "$USER"
EOF
exit 0
