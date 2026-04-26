import Foundation

/// State of a VPN connection inside the guest VM (IKEv2 / WireGuard / WARP).
///
/// Shared across all VPN bridges so the UI layer can render a single
/// connection-status surface regardless of which transport is in use.
public enum VPNConnectionState: Equatable {
    /// Initial state — haven't heard from the agent yet.
    case unknown
    /// VPN is connected and routing traffic.
    case connected
    /// VPN is in the process of connecting (e.g. happy eyeballs).
    case connecting
    /// VPN is not connected (but could be started).
    case disconnected
    /// VPN client binaries are not installed in the VM.
    case notInstalled
    /// Something went wrong — includes a human-readable message.
    case error(String)

    public var isConnected: Bool { self == .connected }
}

/// Legacy spelling — predates the multi-VPN refactor where this enum was
/// pulled out of WarpBridge.swift. Kept as a typealias so call sites can
/// migrate at their own pace.
public typealias WarpState = VPNConnectionState
