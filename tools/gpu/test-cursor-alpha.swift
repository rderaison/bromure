import Foundation
import IOSurface
// Display test uses the real worker pipe, without the VM/XPC session.
final class MacOS27RendererClient {
    struct Reply { let command: Data; let surface: IOSurface? }
    func stop() {}
    func execute(_ data: Data, completion: @escaping (Result<Reply, Error>) -> Void) { fatalError("Unused XPC test stub") }
}
@main struct CursorAlphaTest {
    static func command(_ type: UInt32, _ body: [UInt32]) -> Data {
        var result = Data()
        for value in [type,0,0,0,0,0] + body {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        return result
    }
    static func main() throws {
        let processor = try RendererCommandProcessor(executable: CommandLine.arguments[1])
        defer { processor.stop() }
        var pixels = Data(repeating: 0, count: 64*64*4)
        pixels.replaceSubrange(0..<12, with: [10,20,30,0,40,50,60,128,70,80,90,255])
        let read: (UInt64,Int) throws -> Data = { address, count in
            pixels.subdata(in: Int(address-1)..<Int(address-1)+count)
        }
        for format: UInt32 in [1,2] {
            let id = format
            _ = try processor.forward(command(0x101,[id,format,64,64]), readGuest:read, writeGuest:{_,_ in})
            _ = try processor.forward(command(0x106,[id,1,1,0,UInt32(pixels.count),0]), readGuest:read, writeGuest:{_,_ in})
            let (rgba,w,h) = try processor.cursorImage(resource:id,readGuest:read)
            precondition(w == 64 && h == 64)
            precondition(Array(rgba.prefix(12)) == [30,20,10,0,60,50,40,128,90,80,70,255])
        }
        print("BROMURE_CURSOR_ALPHA_PASS:BGRA swizzle and alpha0/128/255 preserved for formats1/2")
    }
}
