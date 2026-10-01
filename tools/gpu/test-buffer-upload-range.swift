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
        // Page-unique contents detect page substitution/reordering, unlike UInt8(offset).
        var guest = Data()
        for word in 0..<size/8 {
            var unique = (UInt64(word) ^ 0x98ab76543210fedc).littleEndian
            withUnsafeBytes(of:&unique) { guest.append(contentsOf:$0) }
        }
        var reads: [(UInt64, Int)] = []
        func guestOffset(_ address: UInt64) -> Int {
            address < 10000000 ? Int(address-1) : split + Int(address-10000000)
        }
        let read: (UInt64,Int) throws -> Data = { address, count in
            reads.append((address,count)); let start = guestOffset(address)
            return guest.subdata(in:start..<start+count)
        }
        let write: (UInt64,Data) throws -> Void = { address, bytes in
            let start = guestOffset(address)
            guest.replaceSubrange(start..<start+bytes.count,with:bytes)
        }
        func forward(_ c: Data) throws {
            let r = try processor.forward(c,readGuest:read,writeGuest:write)
            precondition(r.withUnsafeBytes { $0.loadUnaligned(as:UInt32.self) } == 0x1100)
        }
        func transfer(_ type: UInt32, id: UInt32 = 1, x: Int, count: Int, offset: Int) throws {
            try forward(command(type,[UInt32(x),0,0,UInt32(count),1,1,UInt32(offset),0,id,0,0,0],context:7))
        }
        func encoded(direction: UInt32, x: Int, count: Int, offset: Int) throws {
            let body: [UInt32] = [43 | (13<<16),1,0,0,0,0,UInt32(x),0,0,UInt32(count),1,1,UInt32(offset),direction]
            try forward(command(0x207,[UInt32(body.count*4),0]+body,context:7))
        }
        try forward(command(0x200,[UInt32](repeating:0,count:18),context:7))
        try forward(command(0x204,[1,0,64,1<<17,UInt32(size),1,1,1,0,0,0,0]))
        try forward(command(0x202,[1,0],context:7))
        try forward(command(0x106,[1,2,1,0,UInt32(split),0,10000000,0,UInt32(size-split),0]))
        let source = guest.subdata(in:69500..<70524)
        try transfer(0x205,x:90000,count:1024,offset:69500)
        precondition(reads.map{$0.1} == [500,524])
        precondition(reads[0].0 == 69501 && reads[1].0 == 10000000)
        precondition(processor.backingUploadStatistics.requests == 1 && processor.backingUploadStatistics.bytes == 1024)
        var expected = guest
        expected.replaceSubrange(69800..<70824,with:source)
        // Destination crosses noncontiguous guest pages; ALL other bytes stay intact.
        try transfer(0x206,x:90000,count:1024,offset:69800)
        precondition(guest == expected)
        reads.removeAll()
        let encodedSource = guest.subdata(in:1234..<1266)
        try encoded(direction:1,x:100,count:32,offset:1234)
        precondition(reads.count == 1 && reads[0].0 == 1235 && reads[0].1 == 32)
        expected = guest; expected.replaceSubrange(200000..<200032,with:encodedSource)
        try encoded(direction:2,x:100,count:32,offset:200000)
        precondition(guest == expected)
        reads.removeAll()
        for type: UInt32 in [0x205,0x206] {
            do {
                _ = try processor.forward(command(type,[0,0,0,100,1,1,UInt32(size-50),0,1,0,0,0],context:7),readGuest:read,writeGuest:write)
                fatalError("Out-of-backing range accepted")
            } catch { precondition(reads.isEmpty) }
        }
        let priorShort = processor.backingUploadStatistics
        do {
            _ = try processor.forward(command(0x205,[0,0,0,1024,1,1,69500,0,1,0,0,0],context:7),readGuest:{_,count in Data(repeating:0,count:count-1)},writeGuest:write)
            fatalError("Short guest read accepted")
        } catch { precondition(processor.backingUploadStatistics.requests == priorShort.requests) }
        try forward(command(0x204,[2,0,64,1<<17,UInt32(size),1,1,1,0,0,0,0]))
        try forward(command(0x202,[2,0],context:7))
        var pages: [UInt32] = [2,UInt32(size/4096)]
        for offset in stride(from:0,to:size,by:4096) { pages += [UInt32(offset+1),0,4096,0] }
        try forward(command(0x106,pages))
        let prior = processor.backingUploadStatistics
        expected = guest
        try transfer(0x205,id:2,x:0,count:size,offset:0)
        let after = processor.backingUploadStatistics
        precondition(after.bytes-prior.bytes == UInt64(size))
        precondition(after.requests-prior.requests == UInt64((size+65495)/65496))
        guest = Data(repeating:0xaa,count:size)
        try transfer(0x206,id:2,x:0,count:size,offset:0)
        precondition(guest == expected)
        for length in [65495,65496,65497] {
            let source = guest.subdata(in:2345..<2345+length)
            let before = processor.backingUploadStatistics
            try transfer(0x205,x:567890,count:length,offset:2345)
            precondition(processor.backingUploadStatistics.requests-before.requests == UInt64((length+65495)/65496))
            expected = guest; expected.replaceSubrange(3456..<3456+length,with:source)
            try transfer(0x206,x:567890,count:length,offset:3456)
            precondition(guest == expected)
        }
        print("BROMURE_BUFFER_BATCH_PASS:1024 guest pages into65 bounded uploads, full unique-data roundtrip and65495/65496/65497 boundaries")
        print("BROMURE_BUFFER_RANGE_PASS:cross-SG control+encoded ranges, mutable sentinels, distinct x/offset, bounds and short-read rejection")
    }
}
