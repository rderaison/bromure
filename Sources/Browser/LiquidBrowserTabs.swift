import AppKit
import SwiftUI
import CompactTabStrip
import BrowserBridges

/// Uses the upstream drag/reorder/tear-off state machine. Chromium target IDs
/// are stable across moves, so a drag never identifies a page by title or URL.
@available(macOS 27.0, *)
struct LiquidBrowserTabs: View {
    @Bindable var model: NativeTabBarModel

    private func identity(_ target: String) -> UUID? {
        guard target.count == 32 else { return nil }
        let chars = Array(target)
        let text = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
            .map { String(chars[$0]) }.joined(separator: "-")
        return UUID(uuidString: text)
    }
    private func target(_ id: UUID) -> String? {
        model.tabs.first { identity($0.id) == id }?.id
    }
    var body: some View {
        let items = model.tabs.compactMap { tab -> CompactTabItem? in
            guard let id = identity(tab.id) else { return nil }
            return CompactTabItem(id: id,
                title: NativeTabBarModel.isNewTabURL(tab.url) ? "New Tab" : (tab.title.isEmpty ? tab.url : tab.title),
                address: tab.url, iconImage: tab.faviconPNG.flatMap(NSImage.init(data:)),
                isBusy: model.navigatingTabID == tab.id,
                hoverContent: .init(title: tab.title, subtitle: tab.url))
        }
        CompactTabStrip(items: items,
            selection: model.activeTab.flatMap { identity($0.id) } ?? items.first?.id ?? UUID(),
            onSelect: { if let id = target($0) { model.onActivate?(id) } },
            onClose: { if let id = target($0) { model.onClose?(id) } },
            onInsert: { model.onNewTab?() },
            onMove: { if let id = target($0) { model.moveTab(id, to: $1) } },
            onDetach: { if let id = target($0) { model.onDetach?(id, $1) } },
            onReload: { if let id = model.activeTab?.id { model.onReload?(id) } },
            allowsPinning: false, labelMode: .fixed, previewImage: { model.dragPreview?() }, transferOwner: model)
            .frame(height: 36)
            .padding(.horizontal, 8)
    }
}
