import AppKit
import SandboxEngine
import SwiftUI

/// One row of the profile chip's menu (and of File ▸ New Window With
/// Profile). Built fresh by the app delegate each time the menu renders.
struct ProfileMenuEntry: Identifiable, Equatable {
    let id: UUID
    let name: String
    let color: ProfileColor?
    let isManaged: Bool
    let isPersistent: Bool
    /// The profile the hosting window runs.
    let isCurrent: Bool
    /// A window for this profile is already open (persistent profiles get
    /// exactly one; picking it focuses that window instead of booting).
    let hasOpenWindow: Bool
}

/// Colour helpers shared by the chip, the File menu and the URL picker.
enum ProfileSwatch {
    static func nsColor(for color: ProfileColor) -> NSColor {
        switch color {
        case .blue: return .systemBlue
        case .red: return .systemRed
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .teal: return .systemTeal
        case .gray: return .systemGray
        }
    }

    /// A filled dot for NSMenu items. Drawn (not a template image) so the
    /// menu keeps the colour; a ring for colourless profiles.
    static func dotImage(for color: ProfileColor?, diameter: CGFloat = 10) -> NSImage {
        let size = NSSize(width: diameter + 2, height: diameter + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(ovalIn: inset)
            if let color {
                nsColor(for: color).setFill()
                path.fill()
            } else {
                NSColor.tertiaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Safari's toolbar profile pill: a person glyph tinted with the profile
/// colour, the profile name and a chevron. The menu behind it lists every
/// profile (current one checked) and the create / edit / delete actions,
/// so the old launcher window is no longer needed for any of that.
struct ProfileChip: View {
    @Bindable var model: NativeTabBarModel

    var body: some View {
        // Reading the version ties this view to the delegate's bumps so
        // the entries closure is re-run after a create / delete / open.
        let _ = model.profileVersion
        let entries = model.profileEntries()
        let name = model.profileName ?? ""

        Menu {
            ForEach(entries) { entry in
                if entry.isCurrent {
                    // A checked, inert row: Safari marks the window's own
                    // profile the same way.
                    Toggle(isOn: .constant(true)) {
                        Label {
                            Text(entry.name)
                        } icon: {
                            Image(nsImage: ProfileSwatch.dotImage(for: entry.color))
                        }
                    }
                } else {
                    Button {
                        model.onOpenProfile?(entry.id)
                    } label: {
                        Label {
                            Text(entry.hasOpenWindow && entry.isPersistent
                                 ? String(format: NSLocalizedString("%@ (open)", comment: "Profile menu row for a profile whose window is already open"), entry.name)
                                 : entry.name)
                        } icon: {
                            Image(nsImage: ProfileSwatch.dotImage(for: entry.color))
                        }
                    }
                }
            }

            Divider()

            Button(NSLocalizedString("New Profile\u{2026}", comment: "")) {
                model.onNewProfile?()
            }
            Button(model.profileIsManaged
                   ? String(format: NSLocalizedString("View \u{201C}%@\u{201D} Settings\u{2026}", comment: "Profile menu: read-only settings of a managed profile"), name)
                   : String(format: NSLocalizedString("Edit \u{201C}%@\u{201D}\u{2026}", comment: "Profile menu: edit the current profile"), name)) {
                model.onEditProfile?()
            }
            Button(String(format: NSLocalizedString("Delete \u{201C}%@\u{201D}\u{2026}", comment: "Profile menu: delete the current profile"), name)) {
                model.onDeleteProfile?()
            }
            .disabled(model.profileIsManaged)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.profileIsManaged ? "lock.shield.fill" : "person.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.profileColor.map { ProfileSettingsView.swiftUIColor(for: $0) } ?? Color.secondary)
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.gray.opacity(0.18)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(format: NSLocalizedString("Profile: %@", comment: "Tooltip of the profile chip"), name))
    }
}
