#!/usr/bin/python3
"""Bromure AC — Kubernetes cluster status probe, run on the control-plane node.

Staged into the node's meta share and invoked over the vsock shell channel
(`python3 /mnt/bromure-meta/bromure-k8s-probe.py [--full]`). Emits ONE JSON
object on stdout that the host decodes into `KubeProbe` (KubeCluster.swift):
the dashboard's stat strip, the node/pod/service/storage tables and the
load balancer's view of the Services of type LoadBalancer all come from it.

`--full` adds the heavier queries (pod list per namespace, PVCs, Longhorn
volumes, warning events) — the host only asks for those while a dashboard is
on screen; the lightweight probe (nodes, pod counts, services) runs on a slow
cadence in the background so the sidebar badge and the load balancer keep
working with the dashboard closed.
"""
import json
import os
import subprocess
import sys
import time

os.environ.setdefault("KUBECONFIG", "/etc/rancher/k3s/k3s.yaml")


def kubectl_json(*args, timeout=20):
    try:
        out = subprocess.run(["kubectl", *args, "-o", "json"], capture_output=True,
                             text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except ValueError:
        return None


def kubectl_text(*args, timeout=20):
    try:
        out = subprocess.run(["kubectl", *args], capture_output=True, text=True,
                             timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout if out.returncode == 0 else ""


def parse_cpu(q):
    """Kubernetes CPU quantity → millicores."""
    if not q:
        return 0
    q = str(q)
    try:
        if q.endswith("m"):
            return int(float(q[:-1]))
        if q.endswith("n"):
            return int(float(q[:-1]) / 1_000_000)
        if q.endswith("u"):
            return int(float(q[:-1]) / 1_000)
        return int(float(q) * 1000)
    except ValueError:
        return 0


_MEM_SUFFIX = {"Ki": 1024, "Mi": 1024 ** 2, "Gi": 1024 ** 3, "Ti": 1024 ** 4,
               "K": 1000, "M": 1000 ** 2, "G": 1000 ** 3, "T": 1000 ** 4}


def parse_mem(q):
    """Kubernetes memory quantity → bytes."""
    if not q:
        return 0
    q = str(q)
    for suf, mult in _MEM_SUFFIX.items():
        if q.endswith(suf):
            try:
                return int(float(q[:-len(suf)]) * mult)
            except ValueError:
                return 0
    try:
        return int(float(q))
    except ValueError:
        return 0


def probe_nodes():
    nodes = []
    doc = kubectl_json("get", "nodes") or {}
    # `kubectl top` needs metrics-server (k3s bundles it; data appears ~1 min
    # after boot). Absent → usage stays 0 and the UI shows "—".
    usage = {}
    for line in kubectl_text("top", "nodes", "--no-headers", timeout=15).splitlines():
        parts = line.split()
        if len(parts) >= 5:
            usage[parts[0]] = (parse_cpu(parts[1]), parse_mem(parts[3]))
    pods_per_node = {}
    for p in (kubectl_json("get", "pods", "-A") or {}).get("items", []):
        n = (p.get("spec") or {}).get("nodeName")
        if n:
            pods_per_node[n] = pods_per_node.get(n, 0) + 1
    for item in doc.get("items", []):
        meta = item.get("metadata", {})
        status = item.get("status", {})
        labels = meta.get("labels", {})
        conds = {c.get("type"): c.get("status") for c in status.get("conditions", [])}
        roles = [k.split("/", 1)[1] for k in labels if k.startswith("node-role.kubernetes.io/")]
        addr = ""
        for a in status.get("addresses", []):
            if a.get("type") == "InternalIP":
                addr = a.get("address", "")
                break
        cap = status.get("allocatable") or status.get("capacity") or {}
        cpu_used, mem_used = usage.get(meta.get("name"), (0, 0))
        nodes.append({
            "name": meta.get("name", ""),
            "ready": conds.get("Ready") == "True",
            "roles": sorted(roles),
            "ip": addr,
            "version": (status.get("nodeInfo") or {}).get("kubeletVersion", ""),
            "cpuCapacityM": parse_cpu(cap.get("cpu")),
            "memCapacityBytes": parse_mem(cap.get("memory")),
            "cpuUsedM": cpu_used,
            "memUsedBytes": mem_used,
            "pods": pods_per_node.get(meta.get("name"), 0),
            "unschedulable": bool((item.get("spec") or {}).get("unschedulable")),
            "pressure": [t for t in ("MemoryPressure", "DiskPressure", "PIDPressure")
                         if conds.get(t) == "True"],
        })
    return nodes


def probe_pods(full):
    doc = kubectl_json("get", "pods", "-A") or {}
    summary = {"total": 0, "running": 0, "pending": 0, "failed": 0,
               "succeeded": 0, "unknown": 0}
    by_ns = {}
    pods = []
    for p in doc.get("items", []):
        meta = p.get("metadata", {})
        status = p.get("status", {})
        phase = (status.get("phase") or "Unknown").lower()
        summary["total"] += 1
        summary[phase if phase in summary else "unknown"] += 1
        ns = meta.get("namespace", "")
        by_ns[ns] = by_ns.get(ns, 0) + 1
        if full:
            cs = status.get("containerStatuses") or []
            ready = sum(1 for c in cs if c.get("ready"))
            restarts = sum(int(c.get("restartCount") or 0) for c in cs)
            # The reason a pod is stuck shows up in a waiting container, not
            # the phase (ImagePullBackOff, CrashLoopBackOff, …).
            reason = ""
            for c in cs:
                w = (c.get("state") or {}).get("waiting")
                if w and w.get("reason"):
                    reason = w["reason"]
                    break
            pods.append({
                "namespace": ns,
                "name": meta.get("name", ""),
                "phase": status.get("phase") or "Unknown",
                "reason": reason,
                "ready": ready,
                "containers": len(cs) or len((p.get("spec") or {}).get("containers", [])),
                "restarts": restarts,
                "node": (p.get("spec") or {}).get("nodeName") or "",
                "createdAt": meta.get("creationTimestamp", ""),
            })
    return summary, by_ns, pods


def probe_services():
    services = []
    doc = kubectl_json("get", "svc", "-A") or {}
    for s in doc.get("items", []):
        meta = s.get("metadata", {})
        spec = s.get("spec", {})
        ports = []
        for p in spec.get("ports", []):
            ports.append({
                "name": p.get("name") or "",
                "port": int(p.get("port") or 0),
                "nodePort": int(p.get("nodePort") or 0),
                "protocol": p.get("protocol") or "TCP",
                "targetPort": str(p.get("targetPort") or ""),
            })
        ingress = []
        for i in ((s.get("status") or {}).get("loadBalancer") or {}).get("ingress", []) or []:
            ingress.append(i.get("ip") or i.get("hostname") or "")
        ann = meta.get("annotations") or {}
        services.append({
            "namespace": meta.get("namespace", ""),
            "name": meta.get("name", ""),
            "type": spec.get("type") or "ClusterIP",
            "clusterIP": spec.get("clusterIP") or "",
            "ports": ports,
            "ingress": [x for x in ingress if x],
            "lbClass": spec.get("loadBalancerClass") or "",
            # A requested LAN address: spec.loadBalancerIP (deprecated upstream
            # but universally understood) or the bromure annotation.
            "lbIP": spec.get("loadBalancerIP") or ann.get("bromure.io/loadBalancerIP")
                    or ann.get("metallb.io/loadBalancerIPs") or "",
        })
    return services


def probe_pvcs():
    pvcs = []
    doc = kubectl_json("get", "pvc", "-A") or {}
    for c in doc.get("items", []):
        meta = c.get("metadata", {})
        spec = c.get("spec", {})
        status = c.get("status", {})
        pvcs.append({
            "namespace": meta.get("namespace", ""),
            "name": meta.get("name", ""),
            "phase": status.get("phase") or "",
            "storageClass": spec.get("storageClassName") or "",
            "capacityBytes": parse_mem((status.get("capacity") or {}).get("storage")),
            "requestBytes": parse_mem(((spec.get("resources") or {}).get("requests") or {}).get("storage")),
            "modes": spec.get("accessModes") or [],
            "volume": spec.get("volumeName") or "",
        })
    return pvcs


def probe_longhorn(full):
    if not kubectl_json("get", "ns", "longhorn-system"):
        return None
    info = {"installed": True, "ready": False, "volumes": [], "nodes": []}
    deploys = kubectl_json("get", "deploy", "-n", "longhorn-system") or {}
    want = ("longhorn-driver-deployer", "csi-provisioner", "longhorn-ui")
    ready = {}
    for d in deploys.get("items", []):
        st = d.get("status", {})
        ready[d.get("metadata", {}).get("name", "")] = \
            (st.get("availableReplicas") or 0) >= (st.get("replicas") or 1)
    # csi-provisioner only exists once the driver deployer ran: ready ⇔ the
    # provisioner is up (the UI is optional).
    info["ready"] = bool(ready.get("csi-provisioner"))
    for n in (kubectl_json("get", "nodes.longhorn.io", "-n", "longhorn-system") or {}).get("items", []):
        st = n.get("status", {})
        conds = {c.get("type"): c.get("status") for c in st.get("conditions", [])}
        maximum = available = 0
        for d in (st.get("diskStatus") or {}).values():
            maximum += int(d.get("storageMaximum") or 0)
            available += int(d.get("storageAvailable") or 0)
        info["nodes"].append({
            "name": n.get("metadata", {}).get("name", ""),
            "ready": conds.get("Ready") == "True",
            "schedulable": conds.get("Schedulable") == "True",
            "storageMaximumBytes": maximum,
            "storageAvailableBytes": available,
        })
    if full:
        for v in (kubectl_json("get", "volumes.longhorn.io", "-n", "longhorn-system") or {}).get("items", []):
            st = v.get("status", {})
            spec = v.get("spec", {})
            info["volumes"].append({
                "name": v.get("metadata", {}).get("name", ""),
                "state": st.get("state") or "",
                "robustness": st.get("robustness") or "",
                "sizeBytes": int(spec.get("size") or 0),
                "actualSizeBytes": int(st.get("actualSize") or 0),
                "replicas": int(spec.get("numberOfReplicas") or 0),
                "node": st.get("currentNodeID") or "",
                "pvc": ((st.get("kubernetesStatus") or {}).get("pvcName") or ""),
                "namespace": ((st.get("kubernetesStatus") or {}).get("namespace") or ""),
            })
    return info


def probe_events():
    events = []
    doc = kubectl_json("get", "events", "-A", "--field-selector", "type=Warning") or {}
    items = doc.get("items", [])
    items.sort(key=lambda e: e.get("lastTimestamp") or e.get("eventTime") or "", reverse=True)
    for e in items[:12]:
        obj = e.get("involvedObject") or {}
        events.append({
            "at": e.get("lastTimestamp") or e.get("eventTime") or "",
            "reason": e.get("reason") or "",
            "message": (e.get("message") or "")[:240],
            "object": "%s/%s" % (obj.get("kind", "").lower(), obj.get("name", "")),
            "namespace": obj.get("namespace") or "",
            "count": int(e.get("count") or 1),
        })
    return events


def probe_deployments():
    total = available = 0
    for d in (kubectl_json("get", "deploy", "-A") or {}).get("items", []):
        st = d.get("status", {})
        total += 1
        if (st.get("availableReplicas") or 0) >= (st.get("replicas") or 0):
            available += 1
    return {"total": total, "available": available}


def main():
    full = "--full" in sys.argv[1:]
    started = time.time()
    version = ""
    vdoc = kubectl_json("version")
    if vdoc:
        version = (vdoc.get("serverVersion") or {}).get("gitVersion", "")
    reachable = bool(vdoc)
    result = {
        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "reachable": reachable,
        "version": version,
        "full": full,
    }
    if reachable:
        summary, by_ns, pods = probe_pods(full)
        result["nodes"] = probe_nodes()
        result["podSummary"] = summary
        result["podsByNamespace"] = by_ns
        result["services"] = probe_services()
        result["deployments"] = probe_deployments()
        lh = probe_longhorn(full)
        if lh:
            result["longhorn"] = lh
        if full:
            result["pods"] = pods
            result["pvcs"] = probe_pvcs()
            result["warnings"] = probe_events()
    result["probeMillis"] = int((time.time() - started) * 1000)
    json.dump(result, sys.stdout, separators=(",", ":"))


if __name__ == "__main__":
    main()
