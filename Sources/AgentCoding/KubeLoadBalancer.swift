import Foundation
import SandboxEngine

// MARK: - Load balancer

/// Bromure's LoadBalancer implementation. Two ways to answer for a Service:
/// - a LAN pool address (`spec.lanPool`, or the Service's own
///   `spec.loadBalancerIP`): the announcer answers ARP for it on the wire
///   and terminates its flows in userspace, MetalLB-style — nothing on the
///   Mac is exposed;
/// - otherwise the Mac's own address: one host listener per (service, port)
///   on 0.0.0.0.
/// Either way each connection is relayed over vsock into the control-plane
/// node and on to the Service's NodePort; the cluster never leaves the VM LAN.
@MainActor
final class KubeLoadBalancer {
    unowned let engine: KubeClusterEngine
    let clusterID: UUID
    let serverNodeID: UUID
    let serverIP: String
    /// The Mac's LAN address (nil = none; only pool addresses can work).
    let hostIP: String?
    /// Spare LAN addresses (host order) handed out to Services.
    let pool: [UInt32]
    /// Service key → LAN address it was given.
    private var assigned: [String: UInt32] = [:]
    /// Addresses the LAN refused (someone else answers), so we don't retry
    /// them on every probe.
    private var refused: [UInt32: String] = [:]

    private final class Listener {
        let fd: Int32
        let key: String
        let target: String
        var thread: Thread?
        init(fd: Int32, key: String, target: String) { self.fd = fd; self.key = key; self.target = target }
    }

    private var listeners: [String: Listener] = [:]
    /// Ports that failed to bind, with the reason — shown in the dashboard.
    private var failures: [String: String] = [:]

    /// UDP on the Mac's own address: one bound socket per (service, port);
    /// every datagram rides the one framed relay into the control-plane
    /// node, and replies come back by NodePort to the socket that owns it.
    private final class UDPListener {
        let fd: Int32
        let key: String
        let nodePort: UInt16
        var thread: Thread?
        init(fd: Int32, key: String, nodePort: UInt16) { self.fd = fd; self.key = key; self.nodePort = nodePort }
    }
    private var udpListeners: [String: UDPListener] = [:]
    private var udpByNodePort: [UInt16: UDPListener] = [:]
    private var udpRelay: KubeUDPRelay?

    /// What answers the cluster's LAN pool addresses (macOS: the
    /// announcer); nil where there is none, and pool services stay pending.
    private let lan: (any KubeLANPublishing)?

    init(engine: KubeClusterEngine, clusterID: UUID, serverNodeID: UUID, serverIP: String,
         hostIP: String?, pool: [UInt32] = [], lan: (any KubeLANPublishing)?) {
        self.lan = lan
        self.engine = engine
        self.clusterID = clusterID
        self.serverNodeID = serverNodeID
        self.serverIP = serverIP
        self.hostIP = hostIP
        self.pool = pool
    }

    /// Bring the listener set in line with the cluster's LoadBalancer
    /// services. Returns the endpoint list for the status snapshot.
    func reconcile(services allServices: [KubeProbe.Service]) -> [KubeLBEndpoint] {
        // `bromure.io/scope: vm` Services live on the VM network (the
        // engine's reconcileVMScope); nothing of theirs touches the LAN.
        let services = allServices.filter { !$0.isVMScoped }
        var desired: [String: (svc: KubeProbe.Service, port: KubeProbe.ServicePort)] = [:]
        var endpoints: [KubeLBEndpoint] = []
        // Services that get their own LAN address are answered by the
        // announcer, not by host listeners.
        let lanServices = reconcileLAN(services: services, endpoints: &endpoints)
        var desiredUDP: [String: (svc: KubeProbe.Service, port: KubeProbe.ServicePort)] = [:]
        for svc in services where !lanServices.contains("\(svc.namespace)/\(svc.name)") {
            for p in svc.ports {
                let key = "\(svc.namespace)/\(svc.name):\(p.port)"
                if p.protocolName.uppercased() == "UDP" {
                    if p.nodePort > 0 { desiredUDP[key] = (svc, p) }
                    else {
                        endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                        nodePort: 0, protocolName: p.protocolName,
                                                        bound: false, error: "no NodePort allocated"))
                    }
                    continue
                }
                guard p.protocolName.uppercased() == "TCP" else {
                    endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                    nodePort: p.nodePort, protocolName: p.protocolName,
                                                    bound: false, error: "\(p.protocolName) isn't relayed"))
                    continue
                }
                guard p.nodePort > 0 else {
                    endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                    nodePort: 0, protocolName: p.protocolName,
                                                    bound: false, error: "no NodePort allocated"))
                    continue
                }
                desired[key] = (svc, p)
            }
        }
        // Close what's gone (or whose NodePort changed).
        for (key, l) in listeners {
            if let d = desired[key], d.port.nodePort == Int(l.target.split(separator: ":").last ?? "") { continue }
            close(l)
            listeners[key] = nil
            failures[key] = nil
        }
        // Open what's new.
        for (key, d) in desired where listeners[key] == nil {
            guard hostIP != nil else {
                failures[key] = "this Mac has no LAN address"
                continue
            }
            let target = "\(serverIP):\(d.port.nodePort)"
            let fd = LBSocket.listenTCP(port: d.port.port)
            if fd < 0 {
                failures[key] = "port \(d.port.port) is in use on this Mac"
                continue
            }
            let l = Listener(fd: fd, key: key, target: target)
            listeners[key] = l
            failures[key] = nil
            startAccepting(l)
        }
        for (key, d) in desired {
            endpoints.append(KubeLBEndpoint(namespace: d.svc.namespace, service: d.svc.name, port: d.port.port,
                                            nodePort: d.port.nodePort, protocolName: d.port.protocolName,
                                            bound: listeners[key] != nil, error: failures[key]))
        }
        reconcileUDP(desiredUDP, endpoints: &endpoints)
        return endpoints.sorted { ($0.namespace, $0.service, $0.port) < ($1.namespace, $1.service, $1.port) }
    }

    private func reconcileUDP(_ desired: [String: (svc: KubeProbe.Service, port: KubeProbe.ServicePort)],
                              endpoints: inout [KubeLBEndpoint]) {
        for (key, l) in udpListeners {
            if let d = desired[key], d.port.nodePort == Int(l.nodePort) { continue }
            closeUDP(l)
            udpListeners[key] = nil
            udpByNodePort[l.nodePort] = nil
            failures[key] = nil
        }
        for (key, d) in desired where udpListeners[key] == nil {
            guard hostIP != nil else { failures[key] = "this Mac has no LAN address"; continue }
            let fd = Self.bindUDP(port: d.port.port)
            if fd < 0 {
                failures[key] = "UDP port \(d.port.port) is in use on this Mac"
                continue
            }
            let l = UDPListener(fd: fd, key: key, nodePort: UInt16(d.port.nodePort))
            udpListeners[key] = l
            udpByNodePort[l.nodePort] = l
            failures[key] = nil
            startReceiving(l)
        }
        for (key, d) in desired {
            endpoints.append(KubeLBEndpoint(namespace: d.svc.namespace, service: d.svc.name, port: d.port.port,
                                            nodePort: d.port.nodePort, protocolName: d.port.protocolName,
                                            bound: udpListeners[key] != nil, error: failures[key]))
        }
    }

    private static func bindUDP(port: Int) -> Int32 {
        let fd = LBSocket.udpSocket()
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                LBSocket.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { LBSocket.close(fd); return -1 }
        return fd
    }

    private func closeUDP(_ l: UDPListener) {
        LBSocket.shutdownBoth(l.fd)
        LBSocket.close(l.fd)
    }

    /// The one relay for every host-port UDP service of this cluster.
    private func ensureUDPRelay() -> KubeUDPRelay {
        if let r = udpRelay, !r.isClosed { return r }
        let engine = self.engine, nodeID = serverNodeID, header = "UDP \(serverIP)"
        let relay = KubeUDPRelay(
            dial: {
                let fd = KubeLANRelay.open({ n, h, done in
                    DispatchQueue.main.async { MainActor.assumeIsolated { engine.openRelay(nodeID: n, target: h, completion: done) } }
                }, nodeID: nodeID, header: header)
                return fd >= 0 ? fd : nil
            },
            onReply: { [weak self] srcIP, srcPort, dstPort, payload in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.deliverUDP(clientIP: srcIP, clientPort: srcPort, nodePort: dstPort, payload: payload) }
                }
            },
            onClosed: { fd in if fd >= 0 { KubeRelayRetain.release(fd: fd) } })
        udpRelay = relay
        return relay
    }

    private func deliverUDP(clientIP: UInt32, clientPort: UInt16, nodePort: UInt16, payload: ArraySlice<UInt8>) {
        guard let l = udpByNodePort[nodePort] else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(clientPort.bigEndian)
        addr.sin_addr.s_addr = clientIP.bigEndian
        let bytes = Array(payload)
        _ = bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    LBSocket.sendto(l.fd, raw.baseAddress, raw.count, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func startReceiving(_ l: UDPListener) {
        let fd = l.fd, nodePort = l.nodePort
        let t = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65535)
            while true {
                var addr = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
                }
                if n < 0 { if errno == EINTR { continue }; return }   // socket closed
                guard n > 0 else { continue }
                let clientIP = UInt32(bigEndian: addr.sin_addr.s_addr)
                let clientPort = UInt16(bigEndian: addr.sin_port)
                let payload = Array(buf[0..<n])
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.ensureUDPRelay().send(srcIP: clientIP, srcPort: clientPort, dstPort: nodePort, payload: payload[...])
                    }
                }
            }
        }
        t.name = "kube-lb-udp:\(l.key)"
        t.start()
        l.thread = t
    }

    func stopAll() {
        for (_, l) in listeners { close(l) }
        listeners.removeAll()
        for (_, l) in udpListeners { closeUDP(l) }
        udpListeners.removeAll()
        udpByNodePort.removeAll()
        udpRelay?.close()
        udpRelay = nil
        failures.removeAll()
        lan?.withdrawAll(owner: clusterID)
        lan?.closeRelays(nodeID: serverNodeID)
        assigned.removeAll()
    }

    // MARK: LAN pool addresses

    /// Give every Service that asks for (or qualifies for) a LAN address its
    /// own IP on the wire. Returns the keys of the Services handled here.
    private func reconcileLAN(services: [KubeProbe.Service], endpoints: inout [KubeLBEndpoint]) -> Set<String> {
        var handled = Set<String>()
        // Nothing to answer pool addresses here: a Service that would get
        // one stays pending, saying so, and never falls back to host ports.
        guard let lan else {
            for svc in services where resolveLANIP(for: svc, key: "\(svc.namespace)/\(svc.name)") != nil {
                handled.insert("\(svc.namespace)/\(svc.name)")
                for p in svc.ports {
                    endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                    nodePort: p.nodePort, protocolName: p.protocolName, bound: false,
                                                    error: "LAN address pools aren't available on this server yet"))
                }
            }
            return handled
        }
        let live = Set(services.map { "\($0.namespace)/\($0.name)" })
        // Services gone → give their addresses back.
        for (key, ip) in assigned where !live.contains(key) {
            lan.withdraw(ip: ip, owner: clusterID, service: key)
            assigned[key] = nil
        }
        // Explicit requests first, then Services already holding one of our
        // addresses (so a restart keeps assignments stable), then the rest —
        // an automatic assignment never grabs an address someone else has a
        // claim to.
        func rank(_ s: KubeProbe.Service) -> Int {
            if !(s.lbIP ?? "").isEmpty { return 0 }
            if s.ingress.contains(where: { ip in VMNetSwitch.parseIPv4(ip).map(pool.contains) ?? false }) { return 1 }
            return 2
        }
        let ordered = services.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return (a.namespace, a.name) < (b.namespace, b.name)
        }
        for svc in ordered {
            let key = "\(svc.namespace)/\(svc.name)"
            guard let ip = resolveLANIP(for: svc, key: key) else { continue }
            handled.insert(key)
            let ipText = VMNetSwitch.ipString(ip)
            var ports: [KubeLANPortKey: KubeLANTarget] = [:]
            for p in svc.ports {
                let proto = p.protocolName.uppercased()
                guard proto == "TCP" || proto == "UDP" else {
                    endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                    nodePort: p.nodePort, protocolName: p.protocolName,
                                                    bound: false, error: "\(p.protocolName) isn't relayed", ip: ipText))
                    continue
                }
                guard p.nodePort > 0, p.port > 0, p.port <= 65535 else {
                    endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                    nodePort: 0, protocolName: p.protocolName,
                                                    bound: false, error: "no NodePort allocated", ip: ipText))
                    continue
                }
                ports[KubeLANPortKey(port: UInt16(p.port), udp: proto == "UDP")] =
                    KubeLANTarget(nodeID: serverNodeID, nodeIP: serverIP, nodePort: UInt16(p.nodePort))
            }
            var error: String?
            var conflicts: [KubeLANPortKey] = []
            if let why = refused[ip] {
                error = why
            } else {
                do {
                    conflicts = try lan.publish(ip: ip, ports: ports, owner: clusterID, service: key)
                    assigned[key] = ip
                } catch {
                    let msg = "\(ipText): \(error.localizedDescription)"
                    refused[ip] = msg
                    if case KubeLANPublishError.inUse = error { assigned[key] = nil }
                }
                error = refused[ip]
            }
            for p in svc.ports where ["TCP", "UDP"].contains(p.protocolName.uppercased()) && p.nodePort > 0 {
                let clash = conflicts.contains(KubeLANPortKey(port: UInt16(p.port), udp: p.protocolName.uppercased() == "UDP"))
                endpoints.append(KubeLBEndpoint(namespace: svc.namespace, service: svc.name, port: p.port,
                                                nodePort: p.nodePort, protocolName: p.protocolName,
                                                bound: error == nil && !clash,
                                                error: error ?? (clash ? "port \(p.port) already used on \(ipText)" : nil),
                                                ip: ipText))
            }
        }
        return handled
    }

    /// Which LAN address a Service gets: the one it asks for, the one it
    /// already holds (ours, or the ingress it was left with before a
    /// restart), else the next free pool address. nil = share the Mac's IP.
    private func resolveLANIP(for svc: KubeProbe.Service, key: String) -> UInt32? {
        if let requested = svc.lbIP, !requested.isEmpty {
            // A requested address is honoured even outside the pool — it's
            // the operator's call, as with metallb.io/loadBalancerIPs.
            if let ip = VMNetSwitch.parseIPv4(requested) { return ip }
        }
        if let ip = assigned[key] { return ip }
        guard !pool.isEmpty else { return nil }
        let taken = Set(assigned.values)
        // Re-adopt the address the Service already shows (stable across app
        // restarts) when it's from our pool and free.
        for ingress in svc.ingress {
            if let ip = VMNetSwitch.parseIPv4(ingress), pool.contains(ip), !taken.contains(ip) { return ip }
        }
        return pool.first { !taken.contains($0) && refused[$0] == nil }
    }

    private func close(_ l: Listener) {
        LBSocket.shutdownBoth(l.fd)
        LBSocket.close(l.fd)
    }

    private func startAccepting(_ l: Listener) {
        let fd = l.fd, target = l.target, nodeID = serverNodeID
        let engine = self.engine
        let t = Thread { [engine] in
            while true {
                var addr = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
                }
                if client < 0 {
                    if errno == EINTR { continue }
                    return   // listener closed
                }
                LBSocket.noSigPipe(client)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        engine.openRelay(nodeID: nodeID, target: target) { vfd in
                            guard vfd >= 0 else { LBSocket.close(client); return }
                            Thread.detachNewThread {
                                LBSocket.splice(vfd, client)
                                KubeRelayRetain.release(fd: vfd)
                            }
                        }
                    }
                }
            }
        }
        t.name = "kube-lb:\(l.key)"
        t.start()
        l.thread = t
    }
}

extension KubeLoadBalancer: KubeServicePublisher {}
