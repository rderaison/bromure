import Foundation

// MARK: - Host Services
//
// Host-guest communication services exposed to the sandboxed VM over vsock.
// The clipboard bridge implementation lives in SandboxEngine/ClipboardBridge.swift
// using VZVirtioSocketDevice for bidirectional clipboard sync.

public enum HostServicesPlaceholder {
    // This exists solely so the HostServices target compiles.
    // Remove this when real services are added.
    public static let version = "0.1.0"
}
