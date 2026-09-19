#!/bin/bash
# Bromure AC — Kubernetes node provisioning, run INSIDE a node VM.
#
# Staged by the host into the node's read-only meta share
# (/mnt/bromure-meta/bromure-k8s-node.sh) and driven over the vsock shell
# channel. Every long step runs DETACHED so the host can poll its log while
# it works (the shell channel is buffered — a 3-minute apt/k3s install would
# otherwise be a silent hang):
#
#   bromure-k8s-node.sh start <step> [args…]   spawn `do-<step>` in the background
#   bromure-k8s-node.sh poll  <step> <offset>  "STATUS running|exit N", "OFFSET n", then log bytes
#   bromure-k8s-node.sh <query>                synchronous one-shots (token, kubeconfig, ip…)
#
# Steps (all idempotent — re-running on a provisioned node is a no-op):
#   prepare <iscsi 0|1> [registries-yaml-b64]  packages, iSCSI, data disk, sysctls,
#                                              containerd registry mirrors
#   server  <name> <noproxy> <k3s-flags…>     k3s server; waits for the API
#   agent   <name> <server-ip> <token> <noproxy>
#   addons  <longhorn 0|1> <replicas> <metallb 0|1> <range|-> <lb-mode> [synology 0|1]
#           Synology: reads /mnt/bromure-meta/synology-client-info.yml +
#           synology-storage-class.yml (staged by the host for this step only)
#   registries <yaml-b64>                     rewrite registries.yaml, restart k3s
#   repoint <server-ip>                       agent: follow a moved control plane
#
# Runs as `ubuntu` (NOPASSWD sudo). The proxy env the shell channel sources
# (/mnt/bromure-meta/proxy.env) is what routes apt / curl / containerd pulls
# through the host MITM; it is forwarded explicitly into every sudo call.

set -u

STATE=/var/lib/bromure-k8s
SELF="$(readlink -f "$0")"
K3S_YAML=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG=$K3S_YAML

# Pinned add-on versions. Overridable from the environment for a one-off try
# of a newer release without a bromure update.
LONGHORN_VERSION="${BROMURE_LONGHORN_VERSION:-v1.9.1}"
METALLB_VERSION="${BROMURE_METALLB_VERSION:-v0.15.2}"
SYNOLOGY_CSI_VERSION="${BROMURE_SYNOLOGY_CSI_VERSION:-v1.2.0}"
REGISTRIES_YAML=/etc/rancher/k3s/registries.yaml

sudo mkdir -p "$STATE" 2>/dev/null
sudo chown ubuntu:ubuntu "$STATE" 2>/dev/null

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

# sudo with the proxy + CA env forwarded (apt, curl, the k3s installer).
proxy_env() {
    local vars=()
    for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY no_proxy \
             SSL_CERT_FILE CURL_CA_BUNDLE REQUESTS_CA_BUNDLE; do
        if [ -n "${!v:-}" ]; then vars+=("$v=${!v}"); fi
    done
    printf '%s\n' "${vars[@]}"
}
psudo() {
    local envs=()
    while IFS= read -r line; do [ -n "$line" ] && envs+=("$line"); done < <(proxy_env)
    sudo env "${envs[@]}" "$@"
}

# ─────────────────────────────── driver ────────────────────────────────────

cmd_start() {
    local step="$1"; shift
    [ -n "$step" ] || { echo "usage: start <step> [args]" >&2; exit 2; }
    local logf="$STATE/$step.log" exitf="$STATE/$step.exit" pidf="$STATE/$step.pid"
    if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
        echo "already running"; exit 0
    fi
    rm -f "$exitf"
    : > "$logf"
    # setsid + nohup: survive the shell channel's subprocess reaping.
    nohup setsid bash -c '
        "$0" "do-$1" "${@:2}"; echo $? > "'"$exitf"'"
    ' "$SELF" "$step" "$@" >> "$logf" 2>&1 < /dev/null &
    echo $! > "$pidf"
    echo "started"
}

cmd_poll() {
    local step="$1" offset="${2:-0}"
    local logf="$STATE/$step.log" exitf="$STATE/$step.exit"
    if [ -f "$exitf" ]; then
        echo "STATUS exit $(cat "$exitf")"
    elif [ -f "$logf" ]; then
        echo "STATUS running"
    else
        echo "STATUS missing"
    fi
    if [ -f "$logf" ]; then
        local size
        size=$(stat -c %s "$logf" 2>/dev/null || echo 0)
        echo "OFFSET $size"
        if [ "$size" -gt "$offset" ]; then
            tail -c +"$((offset + 1))" "$logf"
        fi
    else
        echo "OFFSET 0"
    fi
}

# ─────────────────────────────── steps ─────────────────────────────────────

write_registries() {
    # <base64 yaml> → /etc/rancher/k3s/registries.yaml (containerd mirrors for
    # the bromure registries). Prints "changed" when the file differs.
    local b64="${1:-}"
    [ -n "$b64" ] || return 0
    local tmp; tmp=$(mktemp)
    printf '%s' "$b64" | base64 -d > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    sudo mkdir -p /etc/rancher/k3s
    if sudo cmp -s "$tmp" "$REGISTRIES_YAML" 2>/dev/null; then rm -f "$tmp"; return 0; fi
    sudo install -m 644 "$tmp" "$REGISTRIES_YAML"
    rm -f "$tmp"
    echo changed
}

do_prepare() {
    local storage="${1:-0}" registries="${2:-}"
    log "prepare: iscsi=$storage"
    if [ -n "$registries" ]; then
        write_registries "$registries" >/dev/null && log "containerd registry mirrors written"
    fi

    # Kernel + sysctl bits kube-proxy / flannel want (k3s sets most itself).
    sudo modprobe br_netfilter 2>/dev/null || true
    sudo modprobe overlay 2>/dev/null || true
    printf 'br_netfilter\noverlay\n' | sudo tee /etc/modules-load.d/bromure-k8s.conf >/dev/null
    printf 'net.ipv4.ip_forward = 1\nnet.bridge.bridge-nf-call-iptables = 1\nfs.inotify.max_user_instances = 8192\nfs.inotify.max_user_watches = 524288\n' \
        | sudo tee /etc/sysctl.d/90-bromure-k8s.conf >/dev/null
    sudo sysctl --system >/dev/null 2>&1 || true

    # The base image's dockerd would fight k3s's containerd for cgroups and
    # RAM; a node never uses it.
    sudo systemctl disable --now docker.socket docker.service >/dev/null 2>&1 || true

    if [ "$storage" = "1" ]; then
        log "installing iSCSI initiator + NFS/SMB clients (storage prerequisites)"
        export DEBIAN_FRONTEND=noninteractive
        psudo apt-get update -qq 2>&1 | tail -n 3
        psudo apt-get install -y -qq open-iscsi nfs-common cifs-utils cryptsetup 2>&1 | tail -n 5
        sudo modprobe iscsi_tcp 2>/dev/null || true
        sudo modprobe dm_crypt 2>/dev/null || true
        printf 'iscsi_tcp\ndm_crypt\n' | sudo tee -a /etc/modules-load.d/bromure-k8s.conf >/dev/null
        sudo systemctl enable --now iscsid >/dev/null 2>&1 || true
        # multipathd (if ever installed) claims Longhorn's block devices.
        if command -v multipathd >/dev/null 2>&1; then
            sudo mkdir -p /etc/multipath
            printf 'blacklist {\n    devnode "^sd[a-z0-9]+"\n}\n' | sudo tee /etc/multipath.conf >/dev/null
            sudo systemctl restart multipathd >/dev/null 2>&1 || true
        fi

        # The dedicated data disk: second virtio-blk device (the root disk is
        # vda; the home is a virtiofs share on node VMs, so nothing else
        # claims vdb). Formatted once, mounted by label at Longhorn's default
        # data path.
        local dev=/dev/vdb
        if [ -b "$dev" ]; then
            if [ -z "$(sudo blkid -s TYPE -o value "$dev" 2>/dev/null)" ]; then
                log "formatting $dev (ext4, label bromure-k8s)"
                sudo mkfs.ext4 -q -L bromure-k8s "$dev"
            fi
            sudo mkdir -p /var/lib/longhorn
            if ! grep -q 'LABEL=bromure-k8s' /etc/fstab; then
                echo 'LABEL=bromure-k8s /var/lib/longhorn ext4 defaults,nofail,noatime 0 2' \
                    | sudo tee -a /etc/fstab >/dev/null
            fi
            sudo mount /var/lib/longhorn 2>/dev/null || sudo mount -a
            log "data disk mounted at /var/lib/longhorn ($(df -h /var/lib/longhorn | tail -1 | awk '{print $2}'))"
        else
            log "no data disk attached — Longhorn will use the root filesystem"
            sudo mkdir -p /var/lib/longhorn
        fi
    fi
    log "prepare: done"
}

k3s_installer() {
    # The installer is fetched once and cached: every step reruns through it
    # (idempotent), and re-downloading on each boot is wasteful.
    # stdout is the RESULT (captured by the caller); narrate on stderr.
    local inst="$STATE/install.sh"
    if [ ! -s "$inst" ]; then
        log "fetching k3s installer" >&2
        curl -sfL https://get.k3s.io -o "$inst" || { log "k3s installer download failed" >&2; return 1; }
        chmod +x "$inst"
    fi
    echo "$inst"
}

wait_api() {
    local tries="${1:-90}"
    for _ in $(seq 1 "$tries"); do
        if [ -r "$K3S_YAML" ] && kubectl get --raw /readyz >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

do_server() {
    local name="$1" noproxy="$2"; shift 2
    local flags="$*"
    log "server: node-name=$name flags=[$flags]"
    if systemctl is-active --quiet k3s 2>/dev/null; then
        log "k3s server already installed — restarting to apply flags"
    fi
    local inst; inst=$(k3s_installer) || return 1
    export NO_PROXY="$noproxy" no_proxy="$noproxy"
    export INSTALL_K3S_EXEC="server --node-name $name --write-kubeconfig-mode 644 $flags"
    export INSTALL_K3S_CHANNEL="${BROMURE_K3S_CHANNEL:-stable}"
    if ! psudo INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC" INSTALL_K3S_CHANNEL="$INSTALL_K3S_CHANNEL" \
            NO_PROXY="$noproxy" no_proxy="$noproxy" K3S_NODE_NAME="$name" sh "$inst" 2>&1; then
        log "k3s install failed"; return 1
    fi
    log "waiting for the API server"
    if ! wait_api 120; then log "API server never became ready"; return 1; fi
    log "server: ready ($(kubectl version 2>/dev/null | grep -i server | head -1))"
}

do_agent() {
    local name="$1" server_ip="$2" token="$3" noproxy="$4"
    log "agent: node-name=$name server=$server_ip"
    local inst; inst=$(k3s_installer) || return 1
    export NO_PROXY="$noproxy" no_proxy="$noproxy"
    if ! psudo K3S_URL="https://$server_ip:6443" K3S_TOKEN="$token" \
            INSTALL_K3S_EXEC="agent --node-name $name" \
            INSTALL_K3S_CHANNEL="${BROMURE_K3S_CHANNEL:-stable}" \
            NO_PROXY="$noproxy" no_proxy="$noproxy" K3S_NODE_NAME="$name" sh "$inst" 2>&1; then
        log "k3s agent install failed"; return 1
    fi
    log "agent: joined"
}

do_repoint() {
    local server_ip="$1"
    local envf=/etc/systemd/system/k3s-agent.service.env
    [ -f "$envf" ] || { log "repoint: not an agent"; return 0; }
    if grep -q "K3S_URL=https://$server_ip:6443" "$envf"; then
        log "repoint: already at $server_ip"; return 0
    fi
    sudo sed -i "s#^K3S_URL=.*#K3S_URL=https://$server_ip:6443#" "$envf"
    sudo systemctl restart k3s-agent
    log "repoint: agent now follows $server_ip"
}

wait_nodes() {
    local want="$1" tries="${2:-150}"
    for _ in $(seq 1 "$tries"); do
        local ready
        ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
        if [ "$ready" -ge "$want" ]; then return 0; fi
        sleep 2
    done
    return 1
}

do_registries() {
    # Live update: rewrite the mirrors and bounce k3s so containerd reloads them.
    local out; out=$(write_registries "$1") || { log "registries: bad payload"; return 1; }
    if [ "$out" = "changed" ]; then
        if systemctl is-active --quiet k3s 2>/dev/null; then sudo systemctl restart k3s; log "registries: k3s restarted"
        elif systemctl is-active --quiet k3s-agent 2>/dev/null; then sudo systemctl restart k3s-agent; log "registries: k3s-agent restarted"
        fi
    else
        log "registries: unchanged"
    fi
}

install_synology() {
    # Synology CSI driver (iSCSI LUNs / SMB shares on a DSM volume). The
    # host staged client-info.yml + the storage class into the meta share
    # for this step; the Secret is the only place the password persists.
    local info=/mnt/bromure-meta/synology-client-info.yml
    local sc=/mnt/bromure-meta/synology-storage-class.yml
    [ -r "$info" ] || { log "Synology: client-info.yml missing"; return 1; }
    if ! kubectl get ns synology-csi >/dev/null 2>&1; then
        log "installing Synology CSI $SYNOLOGY_CSI_VERSION"
        local src="$STATE/synology-csi"
        if [ ! -d "$src/deploy" ]; then
            rm -rf "$src"
            git clone -q --depth 1 --branch "$SYNOLOGY_CSI_VERSION"                 https://github.com/SynologyOpenSource/synology-csi.git "$src" 2>&1 | tail -n 2                 || { log "Synology CSI clone failed"; return 1; }
        fi
        local dir="$src/deploy/kubernetes/v1.20"
        [ -d "$dir" ] || dir=$(ls -d "$src"/deploy/kubernetes/v1.* 2>/dev/null | sort -V | tail -1)
        [ -d "$dir" ] || { log "Synology CSI manifests not found"; return 1; }
        kubectl apply -f "$dir/namespace.yml" 2>&1 | tail -n 1
        kubectl -n synology-csi delete secret client-info-secret >/dev/null 2>&1 || true
        kubectl -n synology-csi create secret generic client-info-secret --from-file=client-info.yml="$info" 2>&1 | tail -n 1
        local f
        for f in "$dir"/*.yml; do
            case "$f" in *namespace.yml|*storage-class*|*storage_class*) continue ;; esac
            kubectl apply -f "$f" 2>&1 | tail -n 3
        done
    else
        log "Synology CSI already present — refreshing its credentials"
        kubectl -n synology-csi delete secret client-info-secret >/dev/null 2>&1 || true
        kubectl -n synology-csi create secret generic client-info-secret --from-file=client-info.yml="$info" 2>&1 | tail -n 1
        kubectl -n synology-csi rollout restart deploy 2>/dev/null || true
        kubectl -n synology-csi rollout restart statefulset 2>/dev/null || true
        kubectl -n synology-csi rollout restart daemonset 2>/dev/null || true
    fi
    if [ -r "$sc" ]; then
        kubectl apply -f "$sc" 2>&1 | tail -n 1
        # The NAS becomes the default class; the others stay by name.
        kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
        kubectl patch storageclass bromure-longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
        kubectl patch storageclass longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
    fi
    log "Synology CSI configured (default storage class: bromure-synology)"
}

do_addons() {
    local longhorn="$1" replicas="$2" metallb="$3" range="$4" lbmode="${5:-bromure}" synology="${6:-0}"
    log "addons: longhorn=$longhorn replicas=$replicas metallb=$metallb range=$range lb=$lbmode synology=$synology"
    wait_api 60 || { log "API not ready"; return 1; }

    if [ "$longhorn" = "1" ]; then
        if ! kubectl get ns longhorn-system >/dev/null 2>&1; then
            log "installing Longhorn $LONGHORN_VERSION"
            local url="https://raw.githubusercontent.com/longhorn/longhorn/$LONGHORN_VERSION/deploy/longhorn.yaml"
            if ! kubectl apply -f "$url" 2>&1 | tail -n 3; then
                log "Longhorn apply failed"; return 1
            fi
        else
            log "Longhorn already present"
        fi
        # Wait for the CRDs, then size the defaults to the cluster.
        for _ in $(seq 1 60); do
            kubectl get settings.longhorn.io -n longhorn-system default-replica-count >/dev/null 2>&1 && break
            sleep 3
        done
        kubectl -n longhorn-system patch settings.longhorn.io default-replica-count \
            --type=merge -p "{\"value\":\"$replicas\"}" >/dev/null 2>&1 || true
        # A storage class sized for THIS cluster (the stock `longhorn` class
        # insists on 3 replicas). Ours becomes the default; the others stay
        # available by name.
        kubectl apply -f - >/dev/null <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: bromure-longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "$replicas"
  staleReplicaTimeout: "30"
  fsType: "ext4"
  dataLocality: "best-effort"
EOF
        kubectl patch storageclass local-path -p \
            '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
        kubectl patch storageclass longhorn -p \
            '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
        log "Longhorn configured (default storage class: bromure-longhorn, $replicas replica(s))"
    fi

    if [ "$metallb" = "1" ] && [ "$range" != "-" ]; then
        if ! kubectl get ns metallb-system >/dev/null 2>&1; then
            log "installing MetalLB $METALLB_VERSION"
            local url="https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml"
            if ! kubectl apply -f "$url" 2>&1 | tail -n 3; then
                log "MetalLB apply failed"; return 1
            fi
        fi
        log "waiting for the MetalLB controller"
        kubectl -n metallb-system wait --for=condition=available deploy/controller --timeout=300s >/dev/null 2>&1 || true
        # The webhook needs a moment after the deployment reports available.
        for _ in $(seq 1 30); do
            if kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: bromure-pool
  namespace: metallb-system
spec:
  addresses:
  - $range
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: bromure-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - bromure-pool
EOF
            then break; fi
            sleep 3
        done
        log "MetalLB configured (pool $range)"
    fi

    if [ "$synology" = "1" ]; then
        install_synology || return 1
    fi
    log "addons: done"
}

# ─────────────────────────────── queries ───────────────────────────────────

cmd_token() { sudo cat /var/lib/rancher/k3s/server/node-token; }
cmd_kubeconfig() { cat "$K3S_YAML"; }
cmd_ip() {
    local ip
    ip=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}
cmd_ready() { wait_api 1 && echo ready || echo waiting; }
cmd_wait_nodes() { wait_nodes "$1" "${2:-150}" && echo ok || { echo timeout; exit 1; }; }
cmd_patch_lb() {
    # patch-lb <namespace> <name> <ip> — publish a LoadBalancer ingress IP
    # (the host's LAN address) the way a cloud controller would.
    kubectl -n "$1" patch svc "$2" --subresource=status --type=merge \
        -p "{\"status\":{\"loadBalancer\":{\"ingress\":[{\"ip\":\"$3\"}]}}}" 2>&1
}
cmd_clear_lb() {
    kubectl -n "$1" patch svc "$2" --subresource=status --type=merge \
        -p '{"status":{"loadBalancer":{}}}' 2>&1
}

case "${1:-}" in
    start)       shift; cmd_start "$@" ;;
    poll)        shift; cmd_poll "$@" ;;
    do-prepare)  shift; do_prepare "$@" ;;
    do-server)   shift; do_server "$@" ;;
    do-agent)    shift; do_agent "$@" ;;
    do-addons)   shift; do_addons "$@" ;;
    do-registries) shift; do_registries "$@" ;;
    do-repoint)  shift; do_repoint "$@" ;;
    token)       cmd_token ;;
    kubeconfig)  cmd_kubeconfig ;;
    ip)          cmd_ip ;;
    ready)       cmd_ready ;;
    wait-nodes)  shift; cmd_wait_nodes "$@" ;;
    patch-lb)    shift; cmd_patch_lb "$@" ;;
    clear-lb)    shift; cmd_clear_lb "$@" ;;
    *) echo "usage: $0 start|poll|token|kubeconfig|ip|ready|wait-nodes|patch-lb|clear-lb" >&2; exit 2 ;;
esac
