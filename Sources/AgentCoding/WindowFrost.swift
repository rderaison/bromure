import AppKit

// Private window-server API — the same call Ghostty and iTerm2 use for
// terminal background blur. Public alternatives (NSVisualEffectView) wash the
// content with a material tint; this blurs the desktop behind the window's
// transparent regions and nothing else.
@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> UnsafeMutableRawPointer?

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func CGSSetWindowBackgroundBlurRadius(
    _ connection: UnsafeMutableRawPointer?, _ windowNumber: Int, _ radius: Int
) -> Int32

extension NSWindow {
    /// Blur radius applied behind translucent terminal windows so the
    /// see-through area reads as frosted glass rather than raw desktop.
    static let terminalFrostRadius = 20

    /// Frost (blur) whatever shows through this window's transparent regions.
    /// The blur only appears where the window is non-opaque, so opaque chrome
    /// (titlebar, sidebar) is unaffected. Pass 0 to remove. Idempotent.
    func setBackgroundFrost(radius: Int) {
        // windowNumber is -1 until the window has a window-server backing;
        // both session windows are created with `defer: false`, so in
        // practice it's always valid by the time opacity chrome is applied.
        guard windowNumber >= 0 else { return }
        CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(), windowNumber, radius)
    }
}
