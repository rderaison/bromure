import AppKit
import SandboxEngine
import SwiftUI

/// What the launch picker hands back: the profile to boot and the network
/// that session uses ("nat" for shared, or a bridged interface id like
/// "en0"). The network choice applies to this session only — the profile's
/// saved setting is left alone.
struct LaunchChoice {
    let profileID: UUID
    let network: String
}

/// The profile chooser Bromure shows before every VM boots (launch, ⌘N,
/// a Dock click, "Open a Different Profile…"): pick a profile — or create
/// one — and the network its session boots on. Styled like the starting
/// splash (brand band, then content) since it opens the same flow.
struct LaunchPickerView: View {
    let interfaces: [VMConfig.BridgedInterface]
    let suggestedColor: () -> ProfileColor?
    let onCreateProfile: (String, ProfileColor?) -> Profile
    let onOpen: (LaunchChoice) -> Void
    let onCancel: () -> Void

    @State private var profiles: [Profile]
    @State private var creatingProfile = false
    @State private var profileID: UUID
    @State private var network: String
    @State private var hoveredProfile: UUID?
    @State private var hoveredNewProfile = false
    @FocusState private var listFocused: Bool

    /// Rows shown before the profile list scrolls.
    private static let visibleRows = 5
    private static let rowHeight: CGFloat = 38

    init(profiles: [Profile], initialProfileID: UUID,
         interfaces: [VMConfig.BridgedInterface],
         suggestedColor: @escaping () -> ProfileColor?,
         onCreateProfile: @escaping (String, ProfileColor?) -> Profile,
         onOpen: @escaping (LaunchChoice) -> Void,
         onCancel: @escaping () -> Void) {
        _profiles = State(initialValue: profiles)
        self.interfaces = interfaces
        self.suggestedColor = suggestedColor
        self.onCreateProfile = onCreateProfile
        self.onOpen = onOpen
        self.onCancel = onCancel
        _profileID = State(initialValue: initialProfileID)
        let profile = profiles.first { $0.id == initialProfileID }
        _network = State(initialValue: Self.defaultNetwork(for: profile, interfaces: interfaces))
    }

    /// The network a profile would boot on unasked: its own override, else
    /// the app-wide Settings ▸ Network choice. Falls back to shared when the
    /// remembered interface is no longer present (dock unplugged, etc.).
    static func defaultNetwork(for profile: Profile?,
                               interfaces: [VMConfig.BridgedInterface]) -> String {
        let defaults = UserDefaults.standard
        var wanted = profile?.settings.networkInterface ?? ""
        if wanted.isEmpty {
            wanted = defaults.string(forKey: "vm.networkMode") == "bridged"
                ? (defaults.string(forKey: "vm.bridgedInterface") ?? "nat")
                : "nat"
        }
        if wanted != "nat", !interfaces.contains(where: { $0.id == wanted }) {
            return "nat"
        }
        return wanted
    }

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader(height: 118, markWidth: 44)

            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 4) {
                    Text("Start a Browser Session")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Choose a profile and the network it connects through.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

                section("Profile") { profileList }
                section("Network") { networkField }

                HStack(spacing: 10) {
                    Spacer()
                    Button(action: onCancel) {
                        Text("Cancel").padding(.horizontal, 6)
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(action: open) {
                        Text("Open").padding(.horizontal, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 22)
        }
        .frame(width: 400)
        .background(.background)
        .tint(Brand.blue)
        .onChange(of: profileID) { _, newID in
            network = Self.defaultNetwork(for: profiles.first { $0.id == newID },
                                          interfaces: interfaces)
        }
        .onAppear { listFocused = true }
        .sheet(isPresented: $creatingProfile) {
            NewProfileForm(initialColor: suggestedColor()) { name, color in
                let profile = onCreateProfile(name, color)
                profiles.append(profile)
                profileID = profile.id
                creatingProfile = false
                listFocused = true
            } onCancel: {
                creatingProfile = false
            }
        }
    }

    private func open() {
        onOpen(LaunchChoice(profileID: profileID, network: network))
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.leading, 2)
            content()
        }
    }

    // MARK: Profiles

    private var profileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(profiles) { profileRow($0).id($0.id) }
                    newProfileRow
                }
                .padding(4)
            }
            .scrollDisabled(profiles.count + 1 <= Self.visibleRows)
            .frame(height: CGFloat(min(profiles.count + 1, Self.visibleRows)) * (Self.rowHeight + 2) + 6)
            .background(card)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { moveSelection(-1, proxy); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1, proxy); return .handled }
            .onChange(of: profileID) { _, id in proxy.scrollTo(id) }
        }
    }

    /// Last row of the list: create a profile on the spot; it joins the
    /// list selected, ready to open.
    private var newProfileRow: some View {
        let hovered = hoveredNewProfile
        return HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Brand.accent)
                .frame(width: 10, height: 10)
            Text("New Profile\u{2026}")
                .font(.system(size: 13))
                .foregroundStyle(Brand.accent)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hoveredNewProfile = $0 }
        .onTapGesture { creatingProfile = true }
        .id("new-profile")
    }

    private func moveSelection(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard let i = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let next = profiles[max(0, min(profiles.count - 1, i + delta))].id
        profileID = next
        proxy.scrollTo(next)
    }

    private func profileRow(_ p: Profile) -> some View {
        let selected = p.id == profileID
        return HStack(spacing: 10) {
            Group {
                if let color = p.color {
                    Circle().fill(ProfileSettingsView.swiftUIColor(for: color))
                } else {
                    Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                }
            }
            .frame(width: 10, height: 10)
            Text(p.name)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Brand.accent)
                .opacity(selected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Brand.accent.opacity(0.14)
                      : hoveredProfile == p.id ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hoveredProfile = $0 ? p.id : (hoveredProfile == p.id ? nil : hoveredProfile) }
        .onTapGesture {
            profileID = p.id
            listFocused = true
        }
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    // MARK: Network

    private var networkField: some View {
        Menu {
            Picker(selection: $network) {
                Label("Shared (NAT)", systemImage: "network").tag("nat")
                if !interfaces.isEmpty {
                    Divider()
                    ForEach(interfaces) { iface in
                        Label(String(format: NSLocalizedString("Bridged \u{2014} %@", comment: ""),
                                     iface.displayName),
                              systemImage: Self.symbol(for: iface))
                            .tag(iface.id)
                    }
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Brand.accent.opacity(0.14))
                    Image(systemName: networkSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Brand.accent)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(networkTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(networkDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 50)
            .background(card)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var selectedInterface: VMConfig.BridgedInterface? {
        interfaces.first { $0.id == network }
    }

    private var networkTitle: String {
        guard let iface = selectedInterface else {
            return NSLocalizedString("Shared (NAT)", comment: "")
        }
        return iface.localizedName ?? iface.id
    }

    private var networkDetail: String {
        guard let iface = selectedInterface else {
            return NSLocalizedString("Shares your Mac's connection", comment: "")
        }
        return String(format: NSLocalizedString("Bridged on %@ · its own address on that network", comment: ""),
                      iface.id)
    }

    private var networkSymbol: String {
        selectedInterface.map(Self.symbol(for:)) ?? "network"
    }

    private static func symbol(for iface: VMConfig.BridgedInterface) -> String {
        let name = (iface.localizedName ?? "").lowercased()
        if name.contains("wi-fi") || name.contains("wifi") || name.contains("wlan") { return "wifi" }
        if name.contains("thunderbolt") { return "bolt.horizontal" }
        if name.contains("ethernet") || name.contains("lan") || name.contains("usb") { return "cable.connector" }
        return "network"
    }

    // MARK: Style

    private var card: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}
