import Foundation
import IOSurface
final class MacOS27RendererClient {
    struct Reply { let command: Data; let surface: IOSurface? }
    func stop() {}
    func execute(_ data: Data, completion: @escaping (Result<Reply, Error>) -> Void) { fatalError("Unused XPC stub") }
}
@main struct BufferRangeTest {
    static func command(_ type: UInt32, _ body: [UInt32], context: UInt32 = 0) -> Data {
        var result = Data()
        for value in [type,0,0,0,context,0] + body {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        return result
    }
    static func main() throws {
        let processor = try RendererCommandProcessor(executable: CommandLine.arguments[1])
        defer { processor.stop() }
        let size = 4 * 1024 * 1024, split = 70000
        let source = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
        var reads: [(UInt64, Int)] = []
        let read: (UInt64,Int) throws -> Data = { address, count in
            reads.append((address,count))
            let offset = address < 10000000 ? Int(address - 1) : split + Int(address - 10000000)
            return source.subdata(in: offset..<offset+count)
        }
        func forward(_ c: Data) throws -> Data {
            let r = try processor.forward(c,readGuest:read,writeGuest:{_,_ in})
            precondition(r.withUnsafeBytes { $0.loadUnaligned(as:UInt32.self) } == 0x1100)
            return r
        }
        _ = try forward(command(0x200,[UInt32](repeating:0,count:18),context:7))
        _ = try forward(command(0x204,[1,0,64,1<<17,UInt32(size),1,1,1,0,0,0,0]))
        _ = try forward(command(0x202,[1,0],context:7))
        _ = try forward(command(0x106,[1,2,1,0,UInt32(split),0,10000000,0,UInt32(size-split),0]))
        // Different buffer x and backing offset: only backing offset selects guest bytes.
        _ = try forward(command(0x205,[90000,0,0,1024,1,1,69500,0,1,0,0,0],context:7))
        precondition(reads.map{$0.1} == [500,524])
        precondition(reads[0].0 == 69501 && reads[1].0 == 10000000)
        reads.removeAll()
        let transfer: [UInt32] = [43 | (13<<16),1,0,0,0,0,100,0,0,32,1,1,1234,1]
        _ = try forward(command(0x207,[UInt32(transfer.count*4),0]+transfer,context:7))
        precondition(reads.count == 1 && reads[0].0 == 1235 && reads[0].1 == 32)
        reads.removeAll()
        do {
            _ = try processor.forward(command(0x205,[0,0,0,100,1,1,UInt32(size-50),0,1,0,0,0],context:7),readGuest:read,writeGuest:{_,_ in})
            fatalError("Out-of-backing range accepted")
        } catch { precondition(reads.isEmpty) }
        print("BROMURE_BUFFER_RANGE_PASS: 4MiB backing uploads only requested1024/32bytes; SG boundary, distinct x/offset, encoded transfer and bounds verified")
    }
}
