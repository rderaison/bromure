import Foundation
import Darwin
import IOSurface

// Bounded command processor confined to a background processing queue.
// Guest memory is accessed only through fresh mappings on the device queue;
// the sandboxed XPC renderer owns parsing, shaders and GPU fence waits.
final class RendererCommandProcessor {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var transport: ((Data) throws -> Data)?
    private var stopTransport: (() -> Void)?
    private struct GuestSpan { let address: UInt64; let count: Int }
    private var backing: [UInt32: [GuestSpan]] = [:]
    private var cursorResources: [UInt32: (width: Int, height: Int, format: UInt32)] = [:]
    private var rejectedCommandCount = 0

    init(executable: String) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--worker"]
        // Do not inherit host tokens, proxy settings or application credentials.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        for handle in [input.fileHandleForWriting, output.fileHandleForReading] {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                stop(); throw failure("Cannot configure renderer pipe")
            }
        }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            stop(); throw failure("Cannot suppress renderer pipe signal")
        }
        // Verify both capability descriptors before advertising VIRGL to Linux.
        do {
        for index: UInt32 in [0, 1] {
            var command = Data(repeating: 0, count: 32)
            put32(0x108, at: 0, into: &command)
            put32(index, at: 24, into: &command)
            let response = try request(command)
            guard response.count == 40, get32(response, at: 0) == 0x1102,
                  get32(response, at: 24) == index + 1,
                  get32(response, at: 28) > 0,
                  get32(response, at: 32) > 0,
                  get32(response, at: 32) <= 65512 else { throw failure("Invalid renderer capset") }
        }
        } catch {
            stop()
            throw error
        }
    }

    @available(macOS 27.0, *)
    init(client: MacOS27RendererClient, onFrame: @escaping (IOSurface) -> Void) throws {
        stopTransport = { client.stop() }
        transport = { [weak self] command in
            dispatchPrecondition(condition: .notOnQueue(.main))
            let ready = DispatchSemaphore(value: 0)
            let box = RendererReplyBox()
            client.execute(command) { result in
                box.lock.lock()
                box.result = result.map { ($0.command, $0.surface) }
                box.lock.unlock()
                ready.signal()
            }
            guard ready.wait(timeout: .now() + 9) == .success else {
                client.stop()
                throw NSError(domain: "BromureRenderer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Renderer completion timed out"])
            }
            box.lock.lock()
            let result = box.result
            box.lock.unlock()
            guard let result else { throw NSError(domain: "BromureRenderer", code: 1) }
            let (response, surface) = try result.get()
            if response.count >= 4 {
                let status = response.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
                if status >= 0x1200, let self {
                    self.rejectedCommandCount += 1
                    if self.rejectedCommandCount <= 40 {
                        let kind = command.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
                        NSLog("[GPU renderer] command=0x%x response=0x%x bytes=%d rejected=%d", kind, status, command.count, self.rejectedCommandCount)
                        if status == 0x1201, self.rejectedCommandCount <= 4 {
                            var diagnostic = Data(repeating: 0, count: 24)
                            put32(0xffff0030, at: 0, into: &diagnostic)
                            if let stats = try? self.request(diagnostic), stats.count >= 40 {
                                let bytes = stats.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt64.self).littleEndian }
                                NSLog("[GPU renderer] live resources=%u contexts=%u accounted bytes=%llu", get32(stats, at: 24), get32(stats, at: 28), bytes)
                            }
                        }
                    }
                }
            }
            if let surface { onFrame(surface) }
            return response
        }
        do {
            for index: UInt32 in [0, 1] {
                var command = Data(repeating: 0, count: 32)
                put32(0x108, at: 0, into: &command); put32(index, at: 24, into: &command)
                let response = try request(command)
                guard response.count == 40, get32(response, at: 0) == 0x1102,
                      get32(response, at: 24) == index + 1,
                      get32(response, at: 28) > 0, get32(response, at: 32) > 0,
                      get32(response, at: 32) <= 65512 else { throw failure("Invalid renderer capset") }
            }
        } catch { stop(); throw error }
    }

    func setDisplay(width: UInt32, height: UInt32) throws {
        var command = Data(repeating: 0, count: 32)
        put32(0xffff0020, at: 0, into: &command)
        put32(width, at: 24, into: &command); put32(height, at: 28, into: &command)
        let response = try request(command)
        guard get32(response, at: 0) == 0x1100 else { throw failure("Display initialization failed") }
    }

    deinit { stop() }

    func stop() {
        stopTransport?()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }

    func logResourceUsage() {
        var command = Data(repeating: 0, count: 24)
        put32(0xffff0030, at: 0, into: &command)
        guard let stats = try? request(command), stats.count >= 64 else { return }
        NSLog("[GPU budget] resources=%u GPU=%llu staging=%llu peakGPU=%llu peakStaging=%llu",
              get32(stats, at: 24), get64(stats, at: 32), get64(stats, at: 40),
              get64(stats, at: 48), get64(stats, at: 56))
        if stats.count >= 88 { NSLog("[GPU budget] limits GPU=%llu staging=%llu resource=%llu", get64(stats, at: 64), get64(stats, at: 72), get64(stats, at: 80)) }
    }

    func reset() throws {
        var command = Data(repeating: 0, count: 24)
        put32(0xffff0001, at: 0, into: &command)
        let response = try request(command)
        guard response.count == 24, get32(response, at: 0) == 0x1100 else {
            throw failure("Renderer reset failed")
        }
        backing.removeAll(); cursorResources.removeAll()
    }

    func forward(_ snapshot: Data,
                 readGuest: (UInt64, Int) throws -> Data,
                 writeGuest: (UInt64, Data) throws -> Void) throws -> Data {
        // Explicit allowlist: host-only reset is never reachable from a guest.
        guard snapshot.count >= 24, snapshot.count <= (get32(snapshot, at: 0) == 0x207 ? 1048576 : 65536),
              [UInt32(0x100), 0x101, 0x102, 0x103, 0x104, 0x105, 0x106, 0x107, 0x108, 0x109, 0x200, 0x201, 0x202, 0x203, 0x204, 0x205, 0x206, 0x207].contains(get32(snapshot, at: 0)) else {
            throw failure("Unsupported control command")
        }
        let type = get32(snapshot, at: 0)
        if type == 0x106 {
            guard snapshot.count >= 32 else { throw failure("Short backing command") }
            let id = get32(snapshot, at: 24), count = Int(get32(snapshot, at: 28))
            guard count > 0, count <= 4094, snapshot.count == 32 + count * 16, backing[id] == nil else {
                throw failure("Invalid backing entries")
            }
            var spans: [GuestSpan] = [], total = 0
            for index in 0..<count {
                let offset = 32 + index * 16
                let address = get64(snapshot, at: offset), length = Int(get32(snapshot, at: offset + 8))
                guard length > 0, length <= 134217728 - total,
                      address <= UInt64.max - UInt64(length) else { throw failure("Invalid backing range") }
                spans.append(GuestSpan(address: address, count: length)); total += length
            }
            let response = try request(backingCommand(0xffff0010, id: id, offset: UInt64(total), count: 0))
            if get32(response, at: 0) == 0x1100 {
                backing[id] = spans
            }
            var guestResponse = Data(snapshot.prefix(24))
            put32(get32(response, at: 0), at: 0, into: &guestResponse)
            // ATTACH_BACKING cannot complete a GPU fence without submitting it.
            if get32(snapshot, at: 4) & 1 != 0 { throw failure("Fenced backing attach unsupported in probe") }
            return guestResponse
        }
        if type == 0x105, snapshot.count == 56 {
            let id = get32(snapshot, at: 48)
            try synchronizeBacking(id, download: false, readGuest: readGuest, writeGuest: writeGuest)
            return try request(snapshot)
        }
        if [UInt32(0x205), 0x206].contains(type), snapshot.count == 72 {
            let id = get32(snapshot, at: 56)
            if let spans = backing[id] {
                if type == 0x205 {
                    var offset: UInt64 = 0
                    for span in spans {
                        var consumed = 0
                        while consumed < span.count {
                            let count = min(65496, span.count - consumed)
                            let chunk = try readGuest(span.address + UInt64(consumed), count)
                            guard chunk.count == count else { throw failure("Short guest upload") }
                            var upload = backingCommand(0xffff0011, id: id, offset: offset, count: count)
                            upload.append(chunk)
                            let reply = try request(upload)
                            guard get32(reply, at: 0) == 0x1100 else { throw failure("Renderer upload rejected") }
                            offset += UInt64(count); consumed += count
                        }
                    }
                }
                let response = try request(snapshot)
                if type == 0x206, get32(response, at: 0) == 0x1100 {
                    var offset: UInt64 = 0
                    for span in spans {
                        var consumed = 0
                        while consumed < span.count {
                            let count = min(65512, span.count - consumed)
                            let reply = try request(backingCommand(0xffff0012, id: id, offset: offset, count: count))
                            guard reply.count == 24 + count, get32(reply, at: 0) == 0x1100 else {
                                throw failure("Renderer readback rejected")
                            }
                            try writeGuest(span.address + UInt64(consumed), Data(reply.dropFirst(24)))
                            offset += UInt64(count); consumed += count
                        }
                    }
                }
                return response
            }
        }
        if type == 0x207, snapshot.count >= 32,
           Int(get32(snapshot, at: 24)) == snapshot.count - 32 {
            var uploads = Set<UInt32>(), downloads = Set<UInt32>(), offset = 32
            while offset + 4 <= snapshot.count {
                let header = get32(snapshot, at: offset), words = Int(header >> 16)
                guard words <= (snapshot.count - offset - 4) / 4 else { throw failure("Truncated VirGL command") }
                let kind = header & 255
                if kind == 45, words == 14 {
                    let resource = get32(snapshot, at: offset + 12 * 4)
                    if get32(snapshot, at: offset + 14 * 4) & 2 != 0 { downloads.insert(resource) }
                    else { uploads.insert(resource) }
                } else if kind == 43, words >= 13 {
                    let resource = get32(snapshot, at: offset + 4)
                    if get32(snapshot, at: offset + 13 * 4) == 2 { downloads.insert(resource) }
                    else { uploads.insert(resource) }
                }
                offset += (words + 1) * 4
            }
            guard offset == snapshot.count else { throw failure("Unaligned VirGL command") }
            for id in uploads { try synchronizeBacking(id, download: false, readGuest: readGuest, writeGuest: writeGuest) }
            let response = try request(snapshot)
            if get32(response, at: 0) == 0x1100 {
                for id in downloads { try synchronizeBacking(id, download: true, readGuest: readGuest, writeGuest: writeGuest) }
            }
            return response
        }
        let response = try request(snapshot)
        if [UInt32(0x102), 0x107].contains(type), snapshot.count == 32, get32(response, at: 0) == 0x1100 {
            backing.removeValue(forKey: get32(snapshot, at: 24))
        }
        if [UInt32(0x101), 0x204].contains(type), get32(response, at: 0) == 0x1100 {
            let offset = type == 0x101 ? 32 : 40
            let width = Int(get32(snapshot, at: offset)), height = Int(get32(snapshot, at: offset + 4))
            let format = get32(snapshot, at: type == 0x101 ? 28 : 32)
            if width > 0 && height > 0 && width <= 64 && height <= 64 && [UInt32(1), 2].contains(format) {
                cursorResources[get32(snapshot, at: 24)] = (width, height, format)
            }
        }
        if type == 0x102, get32(response, at: 0) == 0x1100 { cursorResources.removeValue(forKey: get32(snapshot, at: 24)) }
        return response
    }

    /// Cursor images are small CPU-authored guest buffers, distinct from scanout.
    /// Snapshot only the validated 64x64 image, never export guest/native handles.
    func cursorImage(resource: UInt32, readGuest: (UInt64, Int) throws -> Data) throws -> (Data, Int, Int) {
        guard let info = cursorResources[resource], let spans = backing[resource] else {
            throw failure("Invalid cursor resource")
        }
        let size = info.width * info.height * 4
        var image = Data()
        for span in spans {
            let remaining = size - image.count
            if remaining == 0 { break }
            let count = min(remaining, span.count)
            let bytes = try readGuest(span.address, count)
            guard bytes.count == count else { throw failure("Short cursor image") }
            image.append(bytes)
        }
        guard image.count == size else { throw failure("Short cursor backing") }
        // virtio BGRA -> AppKit RGBA; XRGB cursors are opaque.
        for i in stride(from: 0, to: image.count, by: 4) {
            let blue = image[i]; image[i] = image[i + 2]; image[i + 2] = blue
            if info.format == 2 { image[i + 3] = 255 }
        }
        return (image, info.width, info.height)
    }

    private func synchronizeBacking(_ id: UInt32, download: Bool,
                                    readGuest: (UInt64, Int) throws -> Data,
                                    writeGuest: (UInt64, Data) throws -> Void) throws {
        guard let spans = backing[id] else { throw failure("Missing transfer backing") }
        var offset: UInt64 = 0
        for span in spans {
            var consumed = 0
            while consumed < span.count {
                let count = min(65496, span.count - consumed)
                var command = backingCommand(download ? 0xffff0012 : 0xffff0011,
                                             id: id, offset: offset, count: count)
                if !download {
                    let bytes = try readGuest(span.address + UInt64(consumed), count)
                    guard bytes.count == count else { throw failure("Short guest upload") }
                    command.append(bytes)
                }
                let response = try request(command)
                guard get32(response, at: 0) == 0x1100,
                      response.count == 24 + (download ? count : 0) else { throw failure("Backing transfer failed") }
                if download { try writeGuest(span.address + UInt64(consumed), Data(response.dropFirst(24))) }
                offset += UInt64(count); consumed += count
            }
        }
    }

    private func backingCommand(_ type: UInt32, id: UInt32, offset: UInt64, count: Int) -> Data {
        var command = Data(repeating: 0, count: 40)
        put32(type, at: 0, into: &command); put32(id, at: 24, into: &command)
        put32(UInt32(truncatingIfNeeded: offset), at: 28, into: &command)
        put32(UInt32(offset >> 32), at: 32, into: &command)
        put32(UInt32(count), at: 36, into: &command)
        return command
    }

    private func request(_ command: Data) throws -> Data {
        if let transport { return try transport(command) }
        guard process.isRunning, command.count <= (get32(command, at: 0) == 0x207 ? 1048576 : 65536) else { throw failure("Renderer unavailable") }
        var frame = Data(repeating: 0, count: 4)
        put32(UInt32(command.count), at: 0, into: &frame)
        frame.append(command)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let descriptor = input.fileHandleForWriting.fileDescriptor
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline)
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard written > 0 else { stop(); throw failure("Renderer write failed") }
                offset += written
            }
        }
        let prefix = try readExactly(4, deadline: deadline)
        let count = Int(get32(prefix, at: 0))
        guard count >= 24, count <= 65536 else { stop(); throw failure("Invalid renderer frame") }
        return try readExactly(count, deadline: deadline)
    }

    private func readExactly(_ count: Int, deadline: Double) throws -> Data {
        var result = Data()
        let descriptor = output.fileHandleForReading.fileDescriptor
        while result.count < count {
            try waitFor(descriptor, events: Int16(POLLIN), deadline: deadline)
            var chunk = [UInt8](repeating: 0, count: count - result.count)
            let received = Darwin.read(descriptor, &chunk, chunk.count)
            if received < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard received > 0 else { stop(); throw failure("Renderer exited during request") }
            result.append(contentsOf: chunk.prefix(received))
        }
        return result
    }

    private func waitFor(_ descriptor: Int32, events: Int16, deadline: Double) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { stop(); throw failure("Renderer timed out") }
            var readiness = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&readiness, 1, Int32(min(remaining * 1000, 5000)))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { stop(); throw failure("Renderer pipe failed") }
            guard readiness.revents & events != 0 else { stop(); throw failure("Renderer disconnected") }
            return
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "BromureRendererProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func get32(_ data: Data, at offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
}
func get64(_ data: Data, at offset: Int) -> UInt64 {
    UInt64(get32(data, at: offset)) | UInt64(get32(data, at: offset + 4)) << 32
}
func put32(_ value: UInt32, at offset: Int, into data: inout Data) {
    for index in 0..<4 { data[offset + index] = UInt8((value >> (index * 8)) & 255) }
}

private final class RendererReplyBox {
    let lock = NSLock()
    var result: Result<(Data, IOSurface?), Error>?
}
