import Foundation
import Darwin

@main struct PointerTransportTest {
    static func main() throws {
        var sockets: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { close(sockets[0]); close(sockets[1]) }
        for fd in sockets {
            precondition(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0)
            precondition(fcntl(fd, F_SETNOSIGPIPE, 1) == 0)
        }
        var size: Int32 = 1024
        precondition(setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout.size(ofValue: size))) == 0)
        let queue = PointerWireQueue()
        for i in 0..<256 { precondition(queue.enqueue(x: Double(i) / 256, y: 0.5, buttons: i % 8)) }
        precondition(!queue.enqueue(x: 0, y: 0, buttons: 0))
        var received = Data(), blocked = false
        var bytes = [UInt8](repeating: 0, count: 127)
        while !queue.isEmpty {
            if try !queue.drain(to: sockets[0]) { blocked = true }
            let count = read(sockets[1], &bytes, bytes.count)
            if count > 0 { received.append(contentsOf: bytes.prefix(count)) }
        }
        while true {
            let count = read(sockets[1], &bytes, bytes.count)
            if count <= 0 { break }
            received.append(contentsOf: bytes.prefix(count))
        }
        precondition(blocked, "Pressure test must actually reach EAGAIN")
        let lines = received.split(separator: 10)
        precondition(lines.count == 256)
        for (i, line) in lines.enumerated() {
            let value = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
            precondition(value["buttons"] as! Int == i % 8)
            precondition(value["x"] as! Double == Double(i) / 256)
        }
        for i in 0..<1000 {
            precondition(queue.enqueue(x: Double(i) / 1000, y: 0.5, buttons: 0, coalescingMotion: true))
        }
        precondition(queue.enqueue(x: 1, y: 0.5, buttons: 1))
        precondition(queue.enqueue(x: 1, y: 0.5, buttons: 0))
        let drained = try queue.drain(to: sockets[0])
        precondition(drained)
        var motion = Data()
        while true {
            let count = read(sockets[1], &bytes, bytes.count)
            if count <= 0 { break }
            motion.append(contentsOf: bytes.prefix(count))
        }
        let snapshots = try motion.split(separator: 10).map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
        }
        precondition(snapshots.count == 3)
        precondition(snapshots.map { $0["buttons"] as! Int } == [0, 1, 0])
        precondition(snapshots[0]["x"] as! Double == 0.999)
        queue.clear()
        print("BROMURE_POINTER_TRANSPORT_PASS:256 ordered transitions under real socket pressure; motion coalesced")
    }
}
