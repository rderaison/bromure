#!/bin/sh
# Runs after install and after upgrade, for both .deb and .rpm.
#
# Two things it deliberately does NOT do.
#
# 1. No `systemctl --global enable`. That would enable the unit for every
#    user on the machine, and the Sidecar binds a single fixed SSH port
#    (2223) that Bromure AC connects through. Measured: a second daemon on
#    one box logs
#      couldn't bind 127.0.0.1:2223: bind: address already in use
#    and then keeps running with a dead SSH server. So on any multi-user box
#    every user after the first would get a daemon that looks healthy and is
#    unreachable. Beyond the port, the Sidecar runs a person's agents with
#    that person's credentials, and enrolment is per user and interactive --
#    a service enabled for someone who never enrols is a pointless process.
#    So: print the one line that enables it, and let the person decide.
#
# 2. No restart of anybody's service. Upgrades must not kill running agents,
#    and root cannot reach another user's systemd manager without their
#    session bus. A running daemon keeps the old binary (its inode survives
#    the replacement) until the user restarts it, which is safe: the pane
#    host and the agents in it live through a restart because the unit sets
#    KillMode=process.
set -e

upgrade=0
case "${1:-}" in
    configure) [ -n "${2:-}" ] && upgrade=1 ;;   # dpkg: $2 is the old version
    2)         upgrade=1 ;;                      # rpm: 2 = upgrade
esac

if [ "$upgrade" = 1 ]; then
    cat <<'EOF'
Bromure Sidecar upgraded.

A running daemon keeps the version it started with. To pick this one up:

    systemctl --user daemon-reload
    systemctl --user restart bromure-sidecar

The reload matters: this package replaces the unit file, and a user manager
that has not reloaded restarts from the old definition.

Running agents survive that restart (the unit uses KillMode=process), and
the pane host is replaced only once it has no windows left.
EOF
    exit 0
fi

cat <<'EOF'
Bromure Sidecar installed.

It runs as a systemd USER service, so each person enables it for
themselves -- it runs your agents with your credentials:

    systemctl --user enable --now bromure-sidecar

On a headless server, also enable lingering, or the service stops when you
log out and never starts at boot:

    sudo loginctl enable-linger "$USER"

Then:

    bromure-sidecar status
    bromure-sidecar enroll     # prints a URL to open on a machine with a browser

Note: only one user per machine can run it, because the SSH control port
(2223) is a single fixed port. A second user's daemon starts but cannot
bind it. Change it per user with:

    bromure-sidecar settings sshPort 2224

Docs: /usr/share/doc/bromure-sidecar/README.md
EOF
exit 0
