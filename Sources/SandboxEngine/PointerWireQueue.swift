import Foundation
import Darwin

/// Bounded newline frames. A partial write resumes at its byte offset;
/// EAGAIN leaves both the frame and button transition queued.
final class PointerWireQueue {
    private var frames: [(data: Data, motion: Bool)] = []
    private var offset = 0
    var isEmpty: Bool { frames.isEmpty }

    func enqueue(x: Double, y: Double, buttons: Int, coalescingMotion: Bool = false) -> Bool {
        enqueueFrame(Data("{\"x\":\(x),\"y\":\(y),\"buttons\":\(buttons)}\n".utf8), coalescingMotion: coalescingMotion)
    }

    func enqueueFrame(_ data: Data, coalescingMotion: Bool = false) -> Bool {
        guard data.count <= 1025, data.last == 10 else { return false }
        let frame = (data: data, motion: coalescingMotion)
        if coalescingMotion, frames.last?.motion == true, frames.count > 1 || offset == 0 {
            frames[frames.count - 1] = frame
            return true
        }
        guard frames.count < 256 else { return false }
        frames.append(frame)
        return true
    }

    func rewindPartialFrame() { offset = 0 }
    func clear() { frames.removeAll(); offset = 0 }

    func drain(to descriptor: Int32) throws -> Bool {
        while let queued = frames.first {
            let frame = queued.data
            let count = frame.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), frame.count - offset)
            }
            if count > 0 {
                offset += count
                if offset == frame.count { frames.removeFirst(); offset = 0 }
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return false
            } else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(count == 0 ? EPIPE : errno))
            }
        }
        return true
    }
}
