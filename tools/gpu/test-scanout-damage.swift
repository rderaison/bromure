import Foundation
import IOSurface
final class MacOS27RendererClient {
    struct Reply { let command: Data; let surface: IOSurface? }
    var captures: [UInt32] = []
    var rejectKind: UInt32?
    func stop() {}
    func execute(_ data: Data, completion: @escaping (Result<Reply, Error>) -> Void) {
        var reply = Data(repeating: 0, count: get32(data,at:0) == 0x108 ? 40 : 24)
        put32(get32(data,at:0) == 0x108 ? 0x1102 : 0x1100,at:0,into:&reply)
        if get32(data,at:0) == 0x108 {
            put32(get32(data,at:24)+1,at:24,into:&reply)
            put32(1,at:28,into:&reply); put32(16,at:32,into:&reply)
        }
        if get32(data,at:0) == 0xffff0023 { captures.append(get32(data,at:24)) }
        if get32(data,at:0) == rejectKind { put32(0x1205,at:0,into:&reply) }
        completion(.success(Reply(command:reply,surface:nil)))
    }
}
@main struct DamageTest {
    static func command(_ kind: UInt32,_ body: [UInt32]) -> Data {
        var data=Data()
        for value in [kind,0,0,0,0,0]+body {
            var word=value.littleEndian; withUnsafeBytes(of:&word){data.append(contentsOf:$0)}
        }
        return data
    }
    static func main() throws {
        let done = DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            do { try run() } catch { fatalError(String(describing:error)) }
            done.signal()
        }
        precondition(done.wait(timeout:.now()+10) == .success)
    }
    static func run() throws {
        let client=MacOS27RendererClient()
        let processor=try RendererCommandProcessor(client:client,onDisplayFrame:{_,_ in})
        func forward(_ kind:UInt32,_ body:[UInt32]) throws {
            _=try processor.forward(command(kind,body),readGuest:{_,_ in Data()},writeGuest:{_,_ in})
        }
        for index:UInt32 in 0..<3 { try forward(0x103,[index*100,0,100,100,index,9]) }
        for (rect,expected) in [([UInt32(0),0,100,100],[UInt32]()),
                                ([100,0,100,100],[1]),([200,0,100,100],[2]),
                                ([99,0,102,100],[1,2]),([0,0,300,100],[1,2]),
                                ([0,100,300,1],[]),([300,0,1,100],[])] {
            client.captures=[]; try forward(0x104,rect+[9,0]); precondition(client.captures==expected)
        }
        // Failed commands do not publish frames or change accepted bindings.
        client.rejectKind=0x103
        try forward(0x103,[500,0,100,100,1,9])
        client.rejectKind=nil; client.captures=[]
        try forward(0x104,[100,0,100,100,9,0]); precondition(client.captures==[1])
        client.rejectKind=0x104; client.captures=[]
        try forward(0x104,[0,0,300,100,9,0]); precondition(client.captures.isEmpty)
        client.rejectKind=nil
        // Rebinding, unbinding, resource lifetime and near-UInt32.max arithmetic.
        try forward(0x103,[UInt32.max-100,0,100,100,2,10])
        client.captures=[]; try forward(0x104,[UInt32.max-99,0,1,1,10,0]); precondition(client.captures==[2])
        try forward(0x103,[0,0,0,0,2,0])
        client.captures=[]; try forward(0x104,[UInt32.max-99,0,1,1,10,0]); precondition(client.captures.isEmpty)
        try forward(0x102,[9,0])
        client.captures=[]; try forward(0x104,[0,0,300,100,9,0]); precondition(client.captures.isEmpty)
        print("SCANOUT_DAMAGE_PASS")
    }
}
