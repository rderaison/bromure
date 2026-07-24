import Foundation
import Testing
@testable import bromure_ac

// The TURN UDP-relay data framing: ChannelData (RFC 5766 §11.4) and the rule
// that tells a channel frame apart from a STUN message on the same UDP socket.

@Suite("ChannelData framing")
struct ChannelDataTests {

    @Test("encode/decode round-trips channel + payload")
    func roundTrip() {
        let payload: [UInt8] = Array(0..<200)
        let frame = ChannelData.encode(channel: 0x4001, payload)
        #expect(frame.count == 4 + payload.count)
        #expect(frame[0] == 0x40 && frame[1] == 0x01)
        #expect(Int(frame[2]) << 8 | Int(frame[3]) == payload.count)
        let decoded = ChannelData.decode(frame)
        #expect(decoded?.channel == 0x4001)
        #expect(decoded?.payload == payload)
    }

    @Test("channel frames and STUN messages are distinguishable by the first byte")
    func discrimination() {
        // STUN's first two bits are always 0 (type & 0xC000 == 0); a channel
        // number's are 01. So a single-socket recv loop can route correctly.
        let stun = STUNMessage(type: STUNMessage.allocateRequest).encoded()
        #expect(ChannelData.isChannelData(stun[0]) == false)

        let chan = ChannelData.encode(channel: 0x4000, [1, 2, 3])
        #expect(ChannelData.isChannelData(chan[0]) == true)
        #expect(STUNMessage.decode(chan) == nil)   // not decodable as STUN
    }

    @Test("out-of-range channels and truncated frames are rejected")
    func rejects() {
        // 0x0016 (Send indication method) has top bits 00 → not ChannelData.
        #expect(ChannelData.decode([0x00, 0x16, 0x00, 0x00]) == nil)
        // 0x7FFF is reserved.
        #expect(ChannelData.decode([0x7F, 0xFF, 0x00, 0x00]) == nil)
        // Length claims 8 bytes, only 2 present.
        #expect(ChannelData.decode([0x40, 0x00, 0x00, 0x08, 0x01, 0x02]) == nil)
    }

    @Test("CHANNEL-NUMBER attribute encodes channel + RFFU padding")
    func channelNumberAttr() {
        var m = STUNMessage(type: STUNMessage.channelBindRequest)
        m.add(channelNumber: 0x4002)
        let v = m.attr(STUNMessage.attrChannelNumber)
        #expect(v == [0x40, 0x02, 0x00, 0x00])
    }
}
