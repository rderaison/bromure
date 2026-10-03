import SwiftUI
import SandboxEngine

struct ProfilePickerView: View {
    @Bindable var state: AppState
    let isUnavailable: (UUID) -> Bool
    let onOpen: (UUID) -> Void
    let onEdit: (UUID) -> Void
    let onNew: () -> Void
    let onDelete: (Set<UUID>) -> Void
    @State private var query = ""
    @State private var selection: Set<UUID> = []

    private var profiles: [Profile] {
        let _ = state.profileVersion
        return state.profileManager.allProfiles.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
    }
    private func canDelete(_ profile: Profile) -> Bool {
        !state.profileManager.isManaged(profile.id) && !isUnavailable(profile.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "person.crop.rectangle.stack.fill")
                    .font(.system(size: 28)).foregroundStyle(Brand.accent)
                    .frame(width: 64, height: 64)
                    .background(Brand.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your profiles").font(.system(size: 24, weight: .semibold))
                    Text("Separate spaces for work, home, and everything else.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onNew) { Label("New Profile", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(Brand.accent)
            }.padding(24)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search profiles", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }
            .padding(11).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24).padding(.bottom, 16)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(profiles) { profile in
                        row(profile)
                    }
                    if profiles.isEmpty {
                        ContentUnavailableView("No profiles found", systemImage: "person.crop.circle.badge.questionmark",
                                               description: Text("Try another search or create a profile."))
                    }
                }.padding(.horizontal, 24).padding(.vertical, 4)
            }
            Divider().padding(.top, 12)
            HStack {
                Button("Select All") { selection.formUnion(profiles.filter(canDelete).map(\.id)) }
                    .disabled(profiles.filter(canDelete).isEmpty)
                if !selection.isEmpty { Button("Clear") { selection.removeAll() } }
                Spacer()
                Text(selection.isEmpty ? "Open and managed profiles cannot be deleted." : "\(selection.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { onDelete(selection) } label: {
                    Label("Delete Selected", systemImage: "trash")
                }.disabled(selection.isEmpty)
            }.padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: state.profileVersion) {
            selection = selection.filter { id in
                state.profileManager.profile(withID: id).map(canDelete) ?? false
            }
        }
    }

    private func row(_ profile: Profile) -> some View {
        let managed = state.profileManager.isManaged(profile.id)
        let open = isUnavailable(profile.id)
        let tint = profile.color.map(ProfileSettingsView.swiftUIColor(for:)) ?? Brand.accent
        return HStack(spacing: 14) {
            Toggle("Select \(profile.name)", isOn: Binding(
                get: { selection.contains(profile.id) },
                set: { if $0 { selection.insert(profile.id) } else { selection.remove(profile.id) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!canDelete(profile))
            Image(systemName: managed ? "lock.shield.fill" : "person.fill")
                .font(.system(size: 20)).foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.headline).lineLimit(1)
                Text(managed ? "Managed profile" : (profile.isPersistent ? "Saved browsing data" : "Private session"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if open { Text("Open").font(.caption.weight(.medium)).foregroundStyle(.secondary) }
            Button { onEdit(profile.id) } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless).help("Profile settings")
            Button(open ? "Show" : "Open") { onOpen(profile.id) }.buttonStyle(.bordered)
        }
        .padding(14)
        .background(selection.contains(profile.id) ? Brand.accent.opacity(0.07) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selection.contains(profile.id) ? Brand.accent.opacity(0.4) : Color.primary.opacity(0.06)))
    }
}
