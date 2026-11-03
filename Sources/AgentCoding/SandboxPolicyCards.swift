import SwiftUI

/// The Sandbox Policy pane's building blocks: settings grouped in rounded
/// cards, a label on the left and its control on the right, the way current
/// macOS System Settings lays them out.
struct PolicyCard<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey?
    var icon: String? = nil
    var tint: Color = .accentColor
    var info: LocalizedStringKey? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let icon { PolicyIcon(system: icon, tint: tint, size: 22) }
                    Text(title).font(.headline)
                    if let info { InfoTip(info) }
                    Spacer(minLength: 8)
                    accessory()
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

extension PolicyCard where Accessory == EmptyView {
    init(_ title: LocalizedStringKey?, icon: String? = nil, tint: Color = .accentColor,
         info: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.icon = icon; self.tint = tint; self.info = info
        self.accessory = { EmptyView() }; self.content = content
    }
}

/// A white SF Symbol on a tinted rounded square, as System Settings draws a
/// pane's icon.
struct PolicyIcon: View {
    let system: String
    var tint: Color = .accentColor
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: system)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint.gradient))
    }
}

/// One setting: its name and a one-line caption on the left, the control on
/// the right, the full explanation behind an ⓘ.
struct PolicyRow<Control: View>: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey? = nil
    var info: LocalizedStringKey? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                    if let info { InfoTip(info) }
                }
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }
}

/// A short status line under a setting: a colored dot and the text.
struct PolicyStatus: View {
    enum Tone { case ok, warn, bad, neutral }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(verbatim: text).font(.caption).foregroundStyle(tone == .neutral ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var color: Color {
        switch tone {
        case .ok: .green
        case .warn: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }
}
