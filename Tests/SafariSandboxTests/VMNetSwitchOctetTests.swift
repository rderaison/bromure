import Foundation
import Testing
@testable import SandboxEngine

@Suite("VMNetSwitch octet selection")
struct VMNetSwitchOctetTests {
    @Test("pinned octet is honored when free of host LANs")
    func pinnedFree() {
        #expect(VMNetSwitch.selectOctet(ascending: false, pinned: 127, used: []) == 127)
        #expect(VMNetSwitch.selectOctet(ascending: true, pinned: 127, used: [65, 66]) == 127)
    }

    @Test("pinned octet falls back to the walk when it collides with a host LAN")
    func pinnedCollides() {
        #expect(VMNetSwitch.selectOctet(ascending: false, pinned: 127, used: [127]) == 64)
    }

    @Test("descending walk avoids host octets")
    func descending() {
        #expect(VMNetSwitch.selectOctet(ascending: false, pinned: nil, used: [64, 63]) == 62)
        #expect(VMNetSwitch.selectOctet(ascending: false, pinned: nil, used: []) == 64)
    }

    @Test("ascending walk starts at 65")
    func ascending() {
        #expect(VMNetSwitch.selectOctet(ascending: true, pinned: nil, used: [65]) == 66)
    }

    @Test("out-of-range pin is ignored")
    func badPin() {
        #expect(VMNetSwitch.selectOctet(ascending: false, pinned: 0, used: []) == 64)
        #expect(VMNetSwitch.selectOctet(ascending: false, pinned: 255, used: []) == 64)
    }
}
