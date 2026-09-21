#!/bin/bash
# Bromure AC — private container registry, run INSIDE the registry VM.
#
# Same driver as bromure-k8s-node.sh (detached steps, polled logs):
#   bromure-registry.sh start setup <port>    data disk + `registry:2` under docker
#   bromure-registry.sh poll  setup <offset>
#   bromure-registry.sh probe <port>          JSON: catalog, tags, disk usage
#   bromure-registry.sh ip
#
# The registry serves plain HTTP on <port>; workspaces treat it as an
# insecure registry, clusters as a containerd mirror. Deletion is enabled so
# tags can be removed through the API; the data lives on the dedicated
# disk mounted at /var/lib/bromure-registry.

set -u

STATE=/var/lib/bromure-k8s
SELF="$(readlink -f "$0")"
DATA=/var/lib/bromure-registry
REGISTRY_IMAGE="${BROMURE_REGISTRY_IMAGE:-registry:2}"

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

do_setup() {
    local port="${1:-5000}"
    log "setup: port=$port image=$REGISTRY_IMAGE"
    # Data disk (second virtio-blk device; the home is a virtiofs share on
    # these VMs so nothing else claims vdb).
    if [ -b /dev/vdb ]; then
        if [ -z "$(sudo blkid -s TYPE -o value /dev/vdb 2>/dev/null)" ]; then
            log "formatting /dev/vdb (ext4, label bromure-reg)"
            sudo mkfs.ext4 -q -L bromure-reg /dev/vdb
        fi
        sudo mkdir -p "$DATA"
        if ! grep -q 'LABEL=bromure-reg' /etc/fstab; then
            echo "LABEL=bromure-reg $DATA ext4 defaults,nofail,noatime 0 2" | sudo tee -a /etc/fstab >/dev/null
        fi
        sudo mount "$DATA" 2>/dev/null || sudo mount -a
        log "data disk mounted at $DATA ($(df -h "$DATA" | tail -1 | awk '{print $2}'))"
    else
        sudo mkdir -p "$DATA"
        log "no data disk — images go on the root filesystem"
    fi

    # dockerd is what the base image ships; its proxy + CA were wired by the
    # guest agent at boot, so the image pull goes through the host.
    for _ in $(seq 1 60); do
        docker info >/dev/null 2>&1 && break
        sleep 2
    done
    docker info >/dev/null 2>&1 || { log "docker isn't running"; return 1; }

    if docker inspect bromure-registry >/dev/null 2>&1; then
        log "registry container exists — making sure it runs"
        docker start bromure-registry >/dev/null 2>&1 || true
    else
        log "pulling $REGISTRY_IMAGE"
        docker pull "$REGISTRY_IMAGE" 2>&1 | tail -n 2
        docker run -d --name bromure-registry --restart=always \
            -p "$port:5000" \
            -e REGISTRY_STORAGE_DELETE_ENABLED=true \
            -v "$DATA:/var/lib/registry" \
            "$REGISTRY_IMAGE" >/dev/null || { log "docker run failed"; return 1; }
    fi
    for _ in $(seq 1 30); do
        curl -sf "http://127.0.0.1:$port/v2/" >/dev/null 2>&1 && { log "registry answering on :$port"; log "setup: done"; return 0; }
        sleep 2
    done
    log "registry never answered on :$port"
    return 1
}

cmd_probe() {
    local port="${1:-5000}"
    python3 - "$port" "$DATA" <<'EOF'
import json, os, sys, urllib.request
port, data = sys.argv[1], sys.argv[2]
base = "http://127.0.0.1:%s/v2/" % port
out = {"reachable": False, "repositories": [], "diskUsedBytes": 0, "diskTotalBytes": 0, "at": ""}
import time
out["at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def get(path):
    with urllib.request.urlopen(base + path, timeout=5) as r:
        return json.loads(r.read().decode())
try:
    cat = get("_catalog?n=500")
    out["reachable"] = True
    for name in cat.get("repositories", []) or []:
        try:
            tags = get(name + "/tags/list").get("tags") or []
        except Exception:
            tags = []
        out["repositories"].append({"name": name, "tags": sorted(tags)})
except Exception:
    pass
try:
    st = os.statvfs(data)
    out["diskTotalBytes"] = st.f_blocks * st.f_frsize
    out["diskUsedBytes"] = (st.f_blocks - st.f_bfree) * st.f_frsize
except OSError:
    pass
json.dump(out, sys.stdout, separators=(",", ":"))
EOF
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
    probe)     shift; cmd_probe "$@" ;;
    ip)        cmd_ip ;;
    *) echo "usage: $0 start|poll|probe|ip" >&2; exit 2 ;;
esac
