import Foundation

/// The part of macOS's vmnet switch that shared code reads on Linux: the
/// guest subnet a fat client's `forward` may reach. The daemon's interim
/// switch (InterimSwitch) sets it; there is no vmnet here.
// @port-skip linux-only: stand-in for the vmnet switch (VMNetSwitch.swift is vmnet + Virtualization)
public final class VMNetSwitch: @unchecked Sendable {
    public static let shared = VMNetSwitch()
    private let lock = NSLock()
    private var _subnet: VmnetSubnet?

    // @port-skip linux-only: stand-in
    public var subnet: VmnetSubnet? {
        get { lock.lock(); defer { lock.unlock() }; return _subnet }
        set { lock.lock(); _subnet = newValue; lock.unlock() }
    }
}
