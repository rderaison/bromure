#!/bin/bash
# Bromure AC — Signal / WhatsApp connector, run INSIDE the connector VM.
#
# Same driver as bromure-registry.sh (detached steps, polled logs):
#   bromure-msgbridge.sh start setup        data disk + the two services + relay
#   bromure-msgbridge.sh poll  setup <offset>
#   bromure-msgbridge.sh probe              JSON: services, accounts, inbox
#   bromure-msgbridge.sh ip
#   bromure-msgbridge.sh relay <verb> …     everything else (bromure-msgbridge.py)
#
# Signal runs as signal-cli-rest-api (json-rpc mode), WhatsApp as GOWA
# (whatsmeow) — both containers on the VM's own network, listening on
# localhost only. The relay (a systemd unit) turns their incoming messages
# into one inbox the host drains over the shell channel, and carries the
# host's commands (register, link, send) to their HTTP APIs. Account data
# lives on the dedicated disk at /var/lib/bromure-msgbridge; the images are
# pulled at their latest release when the connector is set up.

set -u

STATE=/var/lib/bromure-k8s
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
DATA=/var/lib/bromure-msgbridge
RELAY="$DIR/bromure-msgbridge.py"
SIGNAL_IMAGE="${BROMURE_SIGNAL_IMAGE:-bbernhard/signal-cli-rest-api:latest}"
WHATSAPP_IMAGE="${BROMURE_WHATSAPP_IMAGE:-aldinokemal2104/go-whatsapp-web-multidevice:latest}"

sudo mkdir -p "$STATE" 2>/dev/null
sudo chown ubuntu:ubuntu "$STATE" 2>/dev/null

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

cmd_start() {
    local step="$1"; shift
    local logf="$STATE/$step.log" exitf="$STATE/$step.exit" pidf="$STATE/$step.pid"
    if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
        echo "already running"; exit 0
    fi
    rm -f "$exitf"
    : > "$logf"
    nohup setsid bash -c '
        "$0" "do-$1" "${@:2}"; echo $? > "'"$exitf"'"
    ' "$SELF" "$step" "$@" >> "$logf" 2>&1 < /dev/null &
    echo $! > "$pidf"
    echo "started"
}

cmd_poll() {
    local step="$1" offset="${2:-0}"
    local logf="$STATE/$step.log" exitf="$STATE/$step.exit"
    if [ -f "$exitf" ]; then echo "STATUS exit $(cat "$exitf")"
    elif [ -f "$logf" ]; then echo "STATUS running"
    else echo "STATUS missing"; fi
    if [ -f "$logf" ]; then
        local size; size=$(stat -c %s "$logf" 2>/dev/null || echo 0)
        echo "OFFSET $size"
        [ "$size" -gt "$offset" ] && tail -c +"$((offset + 1))" "$logf"
    else
        echo "OFFSET 0"
    fi
}

ensure_container() {  # name image run-args…
    local name="$1" image="$2"; shift 2
    if docker inspect "$name" >/dev/null 2>&1; then
        log "$name exists — making sure it runs"
        docker start "$name" >/dev/null 2>&1 || true
        return 0
    fi
    log "pulling $image"
    docker pull "$image" 2>&1 | tail -n 2
    docker run -d --name "$name" --restart=always --network host "$@" "$image" >/dev/null \
        || { log "starting $name failed"; return 1; }
}

do_setup() {
    log "setup: signal=$SIGNAL_IMAGE whatsapp=$WHATSAPP_IMAGE"
    if [ -b /dev/vdb ]; then
        if [ -z "$(sudo blkid -s TYPE -o value /dev/vdb 2>/dev/null)" ]; then
            log "formatting /dev/vdb (ext4, label bromure-msg)"
            sudo mkfs.ext4 -q -L bromure-msg /dev/vdb
        fi
        sudo mkdir -p "$DATA"
        if ! grep -q 'LABEL=bromure-msg' /etc/fstab; then
            echo "LABEL=bromure-msg $DATA ext4 defaults,nofail,noatime 0 2" | sudo tee -a /etc/fstab >/dev/null
        fi
        mountpoint -q "$DATA" || sudo mount "$DATA" 2>/dev/null || sudo mount LABEL=bromure-msg "$DATA"
        log "data disk mounted at $DATA"
    else
        sudo mkdir -p "$DATA"
        log "no data disk — account data goes on the root filesystem"
    fi
    sudo mkdir -p "$DATA/signal" "$DATA/whatsapp"
    sudo chown ubuntu:ubuntu "$DATA"

    for _ in $(seq 1 60); do
        docker info >/dev/null 2>&1 && break
        sleep 2
    done
    docker info >/dev/null 2>&1 || { log "docker isn't running"; return 1; }

    # Native build (no JVM — the machine is 512 MB). 18080: the base
    # image's own guest service already holds 8080.
    ensure_container bromure-signal "$SIGNAL_IMAGE" \
        -e MODE=json-rpc-native -e PORT=18080 \
        -v "$DATA/signal:/home/.local/share/signal-cli" || return 1
    ensure_container bromure-whatsapp "$WHATSAPP_IMAGE" \
        -e APP_PORT=3000 -e APP_HOST=127.0.0.1 -e APP_BASIC_AUTH= \
        -e APP_UI_ENABLED=false -e MCP_ENABLED=false -e APP_OS=Bromure \
        -e WHATSAPP_WEBHOOK=http://127.0.0.1:9000/wa \
        -v "$DATA/whatsapp:/app/storages" || return 1

    # The relay: a systemd unit, so it outlives this shell and comes back
    # with the machine (a resumed snapshot keeps it running as it was).
    sudo tee /etc/systemd/system/bromure-msgbridge.service >/dev/null <<EOF
[Unit]
Description=Bromure Signal/WhatsApp relay
After=docker.service network-online.target

[Service]
User=ubuntu
ExecStart=/usr/bin/python3 $RELAY daemon
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now bromure-msgbridge.service >/dev/null 2>&1
    sudo systemctl restart bromure-msgbridge.service

    # WhatsApp answers its status with an error code until a device is
    # linked — any HTTP answer means it's up.
    wa_up() { [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/app/status 2>/dev/null)" != "000" ]; }
    for _ in $(seq 1 90); do
        if curl -sf http://127.0.0.1:18080/v1/about >/dev/null 2>&1 && wa_up; then
            log "Signal and WhatsApp services answering"
            log "setup: done"
            return 0
        fi
        sleep 2
    done
    curl -sf http://127.0.0.1:18080/v1/about >/dev/null 2>&1 || log "the Signal service never answered"
    wa_up || log "the WhatsApp service never answered"
    return 1
}

cmd_ip() {
    local ip
    ip=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

case "${1:-}" in
    start)     shift; cmd_start "$@" ;;
    poll)      shift; cmd_poll "$@" ;;
    do-setup)  shift; do_setup "$@" ;;
    probe)     python3 "$RELAY" probe ;;
    relay)     shift; python3 "$RELAY" "$@" ;;
    ip)        cmd_ip ;;
    *) echo "usage: $0 start|poll|probe|relay|ip" >&2; exit 2 ;;
esac
