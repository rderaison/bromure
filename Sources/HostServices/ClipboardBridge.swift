import Foundation

// MARK: - Clipboard Bridge (Placeholder)
//
// This module is reserved for future opt-in host services that can be
// exposed to the sandboxed VM over vsock. All channels are disabled
// by default for maximum isolation.
//
// Potential future services:
// - Clipboard relay over VZVirtioSocketDeviceConfiguration (vsock)
// - One-way file drop (host → guest) over vsock
// - Notification relay
//
// Architecture:
//   Host side: listens on a vsock port, relays NSPasteboard contents
//   Guest side: agent connects to vsock, writes to guest pasteboard
//
// These are intentionally NOT implemented to maintain the isolation
// guarantee. Uncomment and implement when/if controlled channels
// are needed.

public enum HostServicesPlaceholder {
    // This exists solely so the HostServices target compiles.
    // Remove this when real services are added.
    public static let version = "0.1.0"
}
