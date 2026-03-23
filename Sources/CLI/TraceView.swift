import SwiftUI
import SandboxEngine
import AppKit

// MARK: - Filter Types

private enum MethodFilter: String, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case other = "OTHER"

    var color: Color {
        switch self {
        case .get: .blue
        case .post: .green
        case .put: .orange
        case .delete: .red
        case .other: .gray
        }
    }

    func matches(_ method: String) -> Bool {
        if self == .other {
            return !["GET", "POST", "PUT", "DELETE"].contains(method.uppercased())
        }
        return method.uppercased() == rawValue
    }

    var filterMethod: String { rawValue }
}

private enum StatusFilter: Int, CaseIterable {
    case s2xx = 2
    case s3xx = 3
    case s4xx = 4
    case s5xx = 5
    case error = 0

    var label: String {
        switch self {
        case .s2xx: "2xx"
        case .s3xx: "3xx"
        case .s4xx: "4xx"
        case .s5xx: "5xx"
        case .error: "Error"
        }
    }

    var color: Color {
        switch self {
        case .s2xx: .green
        case .s3xx: .yellow
        case .s4xx: .orange
        case .s5xx: .red
        case .error: .red
        }
    }

    func matches(_ event: TraceEvent) -> Bool {
        guard let code = event.statusCode else {
            return self == .error && event.errorText != nil
        }
        switch self {
        case .s2xx: return (200...299).contains(code)
        case .s3xx: return (300...399).contains(code)
        case .s4xx: return (400...499).contains(code)
        case .s5xx: return (500...599).contains(code)
        case .error: return event.errorText != nil
        }
    }
}

private enum DetailTab: String, CaseIterable {
    case request = "Request"
    case response = "Response"
    case formFields = "Form Fields"
    case navigation = "Navigation"
    case timing = "Timing"
}

// MARK: - MIME Type Classification

private enum MIMECategory: String {
    case html = "HTML"
    case js = "JS"
    case css = "CSS"
    case json = "JSON"
    case image = "IMG"
    case font = "Font"
    case other = "Other"

    var color: Color {
        switch self {
        case .html: .purple
        case .js: .yellow
        case .css: .blue
        case .json: .green
        case .image: .pink
        case .font: .gray
        case .other: .secondary
        }
    }

    static func from(mimeType: String?) -> MIMECategory {
        guard let mime = mimeType?.lowercased() else { return .other }
        if mime.contains("html") { return .html }
        if mime.contains("javascript") || mime.contains("ecmascript") { return .js }
        if mime.contains("css") { return .css }
        if mime.contains("json") { return .json }
        if mime.contains("image") { return .image }
        if mime.contains("font") || mime.contains("woff") { return .font }
        return .other
    }
}

// MARK: - Main View

struct TraceView: View {
    let events: [TraceEvent]
    let sessionName: String
    let availableHostnames: [String]
    var onFilterChanged: ((TraceFilter) -> Void)?
    var onExport: (() -> Void)?
    var onExportDB: (() -> Void)?
    var onClear: (() -> Void)?
    var onShowFlowGraph: (() -> Void)?

    @State private var searchText = ""
    @State private var bodySearchText = ""
    @State private var activeMethodFilters: Set<MethodFilter> = []
    @State private var activeStatusFilters: Set<StatusFilter> = []
    @State private var selectedHostnames: Set<String> = []
    @State private var selectedTabId: Int?  // nil = all tabs
    @State private var timeFromText = ""
    @State private var timeToText = ""
    @State private var selectedEventID: String?
    @State private var detailTab: DetailTab = .request
    @State private var showBodySearch = false

    /// All distinct tab IDs in the events.
    private var availableTabIds: [Int] {
        Array(Set(events.compactMap(\.tabId))).sorted()
    }

    private var filteredEvents: [TraceEvent] {
        events.filter { event in
            if let tabFilter = selectedTabId {
                guard event.tabId == tabFilter else { return false }
            }
            if !searchText.isEmpty {
                guard event.url.localizedCaseInsensitiveContains(searchText) else { return false }
            }
            if !bodySearchText.isEmpty {
                let inBody = event.responseBody?.localizedCaseInsensitiveContains(bodySearchText) == true
                let inPost = event.postData?.localizedCaseInsensitiveContains(bodySearchText) == true
                guard inBody || inPost else { return false }
            }
            if !activeMethodFilters.isEmpty {
                guard activeMethodFilters.contains(where: { $0.matches(event.method) }) else { return false }
            }
            if !activeStatusFilters.isEmpty {
                guard activeStatusFilters.contains(where: { $0.matches(event) }) else { return false }
            }
            if !selectedHostnames.isEmpty {
                guard let h = event.hostname, selectedHostnames.contains(h) else { return false }
            }
            if let fromSec = Double(timeFromText), let baseTs = events.first?.timestamp {
                guard event.timestamp >= baseTs + fromSec else { return false }
            }
            if let toSec = Double(timeToText), let baseTs = events.first?.timestamp {
                guard event.timestamp <= baseTs + toSec else { return false }
            }
            return true
        }
    }

    private var selectedEvent: TraceEvent? {
        guard let id = selectedEventID else { return nil }
        return events.first { $0.id == id }
    }

    private var timeRange: (start: Double, end: Double) {
        guard let first = filteredEvents.first else { return (0, 1) }
        let start = first.timestamp
        var end = start
        for event in filteredEvents {
            let eventEnd = event.timestamp + (event.duration ?? 0)
            if eventEnd > end { end = eventEnd }
            if event.timestamp > end { end = event.timestamp }
        }
        if end <= start { end = start + 1 }
        return (start, end)
    }

    private var hasActiveFilters: Bool {
        !searchText.isEmpty || !bodySearchText.isEmpty || !activeMethodFilters.isEmpty
            || !activeStatusFilters.isEmpty || !selectedHostnames.isEmpty
            || selectedTabId != nil || !timeFromText.isEmpty || !timeToText.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                timelineTable
                    .frame(minWidth: 520)
                if selectedEvent != nil {
                    detailPane
                        .frame(minWidth: 320, idealWidth: 420, maxWidth: 640)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: searchText) { notifyFilterChanged() }
        .onChange(of: bodySearchText) { notifyFilterChanged() }
        .onChange(of: activeMethodFilters) { notifyFilterChanged() }
        .onChange(of: activeStatusFilters) { notifyFilterChanged() }
        .onChange(of: selectedHostnames) { notifyFilterChanged() }
        .onChange(of: timeFromText) { notifyFilterChanged() }
        .onChange(of: timeToText) { notifyFilterChanged() }
    }

    private func notifyFilterChanged() {
        let filter = TraceFilter(
            searchText: searchText.isEmpty ? nil : searchText,
            hostnames: selectedHostnames,
            methods: Set(activeMethodFilters.map(\.filterMethod)),
            statusCategories: Set(activeStatusFilters.map(\.rawValue)),
            bodyContent: bodySearchText.isEmpty ? nil : bodySearchText,
            timeStart: Double(timeFromText).flatMap { t in events.first.map { $0.timestamp + t } },
            timeEnd: Double(timeToText).flatMap { t in events.first.map { $0.timestamp + t } }
        )
        onFilterChanged?(filter)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 6) {
            // Row 1: Search, counts, actions
            HStack(spacing: 10) {
                // URL search
                SearchField(placeholder: "Filter URLs\u{2026}", text: $searchText, icon: "magnifyingglass")
                    .frame(maxWidth: 260)

                // Body search toggle + field
                if showBodySearch {
                    SearchField(placeholder: "Body content\u{2026}", text: $bodySearchText, icon: "doc.text.magnifyingglass")
                        .frame(maxWidth: 220)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showBodySearch.toggle() }
                    if !showBodySearch { bodySearchText = "" }
                } label: {
                    Image(systemName: showBodySearch ? "doc.text.magnifyingglass" : "doc.text.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(showBodySearch ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Search response/request body content")

                Spacer()

                // Event count
                Text("\(filteredEvents.count) / \(events.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Divider().frame(height: 16)

                // Navigation Graph
                Button { onShowFlowGraph?() } label: {
                    Label("Flow", systemImage: "building.2")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Open isometric flow view in a new window")
                .disabled(onShowFlowGraph == nil)

                Divider().frame(height: 16)

                // Export JSON
                Button { onExport?() } label: {
                    Label("JSON", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Export filtered events as JSON")
                .disabled(onExport == nil)

                // Export DB
                Button { onExportDB?() } label: {
                    Label("DB", systemImage: "cylinder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Export SQLite database")
                .disabled(onExportDB == nil)

                // Clear
                Button { onClear?() } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(onClear == nil)
            }

            // Row 2: Method + Status filters, hostname, time range, reset
            HStack(spacing: 6) {
                // Method filters
                ForEach(MethodFilter.allCases, id: \.self) { method in
                    FilterChip(
                        title: method.rawValue,
                        color: method.color,
                        isActive: activeMethodFilters.contains(method)
                    ) {
                        if activeMethodFilters.contains(method) {
                            activeMethodFilters.remove(method)
                        } else {
                            activeMethodFilters.insert(method)
                        }
                    }
                }

                thinDivider

                // Status filters
                ForEach(StatusFilter.allCases, id: \.self) { status in
                    FilterChip(
                        title: status.label,
                        color: status.color,
                        isActive: activeStatusFilters.contains(status)
                    ) {
                        if activeStatusFilters.contains(status) {
                            activeStatusFilters.remove(status)
                        } else {
                            activeStatusFilters.insert(status)
                        }
                    }
                }

                thinDivider

                // Tab filter
                if availableTabIds.count > 1 {
                    Menu {
                        Button("All Tabs") { selectedTabId = nil }
                        Divider()
                        ForEach(availableTabIds, id: \.self) { tabId in
                            Button {
                                selectedTabId = (selectedTabId == tabId) ? nil : tabId
                            } label: {
                                HStack {
                                    if selectedTabId == tabId {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(verbatim: "Tab \(tabId)")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 9))
                            Text(selectedTabId.map { "Tab \($0)" } ?? "Tabs")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(selectedTabId != nil ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            selectedTabId != nil
                                ? Color.accentColor.opacity(0.12)
                                : Color.primary.opacity(0.05)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    thinDivider
                }

                // Hostname filter
                if !availableHostnames.isEmpty {
                    Menu {
                        ForEach(availableHostnames, id: \.self) { host in
                            Button {
                                if selectedHostnames.contains(host) {
                                    selectedHostnames.remove(host)
                                } else {
                                    selectedHostnames.insert(host)
                                }
                            } label: {
                                HStack {
                                    if selectedHostnames.contains(host) {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(host)
                                }
                            }
                        }
                        Divider()
                        Button("Clear Selection") { selectedHostnames.removeAll() }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "globe")
                                .font(.system(size: 9))
                            Text(selectedHostnames.isEmpty ? "Hosts" : "\(selectedHostnames.count)")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(selectedHostnames.isEmpty ? Color.secondary : Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            selectedHostnames.isEmpty
                                ? Color.primary.opacity(0.05)
                                : Color.accentColor.opacity(0.12)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                thinDivider

                // Time range
                HStack(spacing: 3) {
                    Text("T")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("from", text: $timeFromText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 44)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text("\u{2013}")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                    TextField("to", text: $timeToText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 44)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text("s")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }

                Spacer()

                if hasActiveFilters {
                    Button("Reset") {
                        searchText = ""
                        bodySearchText = ""
                        activeMethodFilters.removeAll()
                        activeStatusFilters.removeAll()
                        selectedHostnames.removeAll()
                        selectedTabId = nil
                        timeFromText = ""
                        timeToText = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var thinDivider: some View {
        Divider().frame(height: 14)
    }

    // MARK: - Timeline Table

    private var timelineTable: some View {
        VStack(spacing: 0) {
            timelineHeader
            Divider()

            List(selection: $selectedEventID) {
                ForEach(Array(filteredEvents.enumerated()), id: \.element.id) { index, event in
                    TimelineRow(
                        event: event,
                        baseTimestamp: timeRange.start,
                        totalDuration: timeRange.end - timeRange.start,
                        isSelected: selectedEventID == event.id,
                        isEvenRow: index % 2 == 0
                    )
                    .tag(event.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var timelineHeader: some View {
        HStack(spacing: 0) {
            Text("Time")
                .frame(width: 76, alignment: .leading)
            Text("Method")
                .frame(width: 58, alignment: .leading)
            Text("Host")
                .frame(width: 100, alignment: .leading)
            Text("URL")
                .frame(minWidth: 120, alignment: .leading)
            Spacer()
            Text("Status")
                .frame(width: 48, alignment: .center)
            Text("Waterfall")
                .frame(width: 140, alignment: .leading)
            Text("Duration")
                .frame(width: 60, alignment: .trailing)
            Text("Type")
                .frame(width: 42, alignment: .center)
            Text("Page")
                .frame(width: 90, alignment: .leading)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        if let event = selectedEvent {
            VStack(spacing: 0) {
                // Header
                HStack {
                    MethodBadge(method: event.method)
                    Text(event.url)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Spacer()
                    Button { selectedEventID = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                // Tab bar
                HStack(spacing: 0) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Button { detailTab = tab } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: detailTab == tab ? .semibold : .regular))
                                .foregroundStyle(detailTab == tab ? .primary : .secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    detailTab == tab
                                        ? Color.accentColor.opacity(0.12)
                                        : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.borderless)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))

                Divider()

                // Content
                ScrollView {
                    switch detailTab {
                    case .request:
                        RequestDetailView(event: event)
                    case .response:
                        ResponseDetailView(event: event)
                    case .formFields:
                        FormFieldsDetailView(event: event)
                    case .navigation:
                        NavigationDetailView(
                            event: event,
                            allEvents: events,
                            baseTimestamp: timeRange.start
                        )
                    case .timing:
                        TimingDetailView(event: event, baseTimestamp: timeRange.start)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

// MARK: - Search Field

private struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.system(size: 10))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.quaternary)
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let title: String
    let color: Color
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isActive ? .white : color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isActive ? color.opacity(0.85) : color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Method Badge

private struct MethodBadge: View {
    let method: String

    private var color: Color {
        switch method.uppercased() {
        case "GET": .blue
        case "POST": .green
        case "PUT": .orange
        case "DELETE": .red
        case "NAVIGATE": .purple
        case "PATCH": .cyan
        default: .gray
        }
    }

    var body: some View {
        Text(method.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let statusCode: Int?
    let errorText: String?

    private var color: Color {
        if errorText != nil && statusCode == nil { return .red }
        guard let code = statusCode else { return .gray }
        switch code {
        case 200...299: return .green
        case 300...399: return .yellow
        case 400...499: return .orange
        case 500...599: return .red
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            if errorText != nil && statusCode == nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                Text("ERR")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            } else if let code = statusCode {
                Text("\(code)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            } else {
                Text("\u{2014}")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
        .foregroundStyle(color)
    }
}

// MARK: - MIME Badge

private struct MIMEBadge: View {
    let mimeType: String?

    private var category: MIMECategory {
        MIMECategory.from(mimeType: mimeType)
    }

    var body: some View {
        Text(category.rawValue)
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(category.color)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(category.color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .help(mimeType ?? "Unknown")
    }
}

// MARK: - Waterfall Bar

private struct WaterfallBar: View {
    let startOffset: Double
    let duration: Double
    let totalDuration: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let leftFrac = totalDuration > 0 ? startOffset / totalDuration : 0
            let widthFrac = totalDuration > 0 ? max(duration / totalDuration, 0.005) : 0.005
            let barX = leftFrac * w
            let barW = max(widthFrac * w, 2)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.quaternary.opacity(0.3))
                    .frame(height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.7))
                    .frame(width: barW, height: 6)
                    .offset(x: barX)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Timeline Row

private struct TimelineRow: View {
    let event: TraceEvent
    let baseTimestamp: Double
    let totalDuration: Double
    let isSelected: Bool
    let isEvenRow: Bool

    private var relativeTime: String {
        let delta = event.timestamp - baseTimestamp
        if delta < 0.001 { return "+0.000s" }
        if delta < 10 { return String(format: "+%.3fs", delta) }
        if delta < 100 { return String(format: "+%.2fs", delta) }
        return String(format: "+%.1fs", delta)
    }

    private var statusColor: Color {
        if event.errorText != nil && event.statusCode == nil { return .red }
        guard let code = event.statusCode else { return .gray }
        switch code {
        case 200...299: return .green
        case 300...399: return .yellow
        case 400...499: return .orange
        case 500...599: return .red
        default: return .gray
        }
    }

    private var durationText: String {
        guard let d = event.duration else { return "\u{2014}" }
        if d < 1 { return String(format: "%.0fms", d * 1000) }
        return String(format: "%.2fs", d)
    }

    private var hostDisplay: String {
        if let h = event.hostname { return h }
        return URL(string: event.url)?.host ?? ""
    }

    private var pathDisplay: String {
        guard let url = URL(string: event.url) else { return event.url }
        var display = url.path
        if let query = url.query { display += "?\(query)" }
        if display.isEmpty { return "/" }
        return display
    }

    private var pageDisplay: String {
        guard let doc = event.documentUrl, let url = URL(string: doc) else { return "" }
        let path = url.path
        return path.isEmpty ? "/" : path
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(relativeTime)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)

            MethodBadge(method: event.method)
                .frame(width: 58, alignment: .leading)

            Text(hostDisplay)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)

            Text(pathDisplay)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
                .help(event.url)
                .frame(minWidth: 120, alignment: .leading)

            Spacer()

            StatusBadge(statusCode: event.statusCode, errorText: event.errorText)
                .frame(width: 48, alignment: .center)

            WaterfallBar(
                startOffset: event.timestamp - baseTimestamp,
                duration: event.duration ?? 0.01,
                totalDuration: totalDuration,
                color: statusColor
            )
            .frame(width: 140, height: 14)

            Text(durationText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)

            MIMEBadge(mimeType: event.mimeType)
                .frame(width: 42, alignment: .center)

            Text(pageDisplay)
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 90, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.15) }
        if event.errorText != nil { return Color.red.opacity(0.04) }
        return isEvenRow ? Color.clear : Color.primary.opacity(0.02)
    }
}

// MARK: - Copy Button with Feedback

private struct CopyButton: View {
    let text: String
    @State private var showCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showCopied = false
            }
        } label: {
            ZStack {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .opacity(showCopied ? 0 : 1)
                HStack(spacing: 2) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Copied")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.green)
                .opacity(showCopied ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.15), value: showCopied)
        }
        .buttonStyle(.borderless)
        .help("Copy to clipboard")
    }
}

// MARK: - Section Header with Copy

private struct SectionHeader<Content: View>: View {
    let title: String
    let copyText: String?
    @ViewBuilder let content: () -> Content

    init(title: String, copyText: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.copyText = copyText
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if let text = copyText {
                    CopyButton(text: text)
                }
            }
            content()
        }
    }
}

// MARK: - Headers Table

private struct HeadersTable: View {
    let headers: [String: String]

    private var sortedHeaders: [(key: String, value: String)] {
        headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
    }

    var headersAsText: String {
        sortedHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(sortedHeaders.enumerated()), id: \.element.key) { index, header in
                HStack(alignment: .top, spacing: 8) {
                    Text(header.key)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.blue.opacity(0.8))
                        .frame(minWidth: 80, alignment: .trailing)
                        .textSelection(.enabled)
                    Text(header.value)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(index % 2 == 0 ? Color.clear : Color.primary.opacity(0.02))
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.2))
        )
    }
}

// MARK: - Syntax Text View

private struct SyntaxTextView: View {
    let text: String
    let mimeHint: String?

    private var isJSON: Bool {
        if let hint = mimeHint?.lowercased(), hint.contains("json") { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    private var prettyText: String {
        guard isJSON,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8)
        else { return text }
        return str
    }

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            Text(prettyText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: 300)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }
}

// MARK: - Request Detail

private struct RequestDetailView: View {
    let event: TraceEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Full URL
            SectionHeader(title: "URL", copyText: event.url) {
                Text(event.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary.opacity(0.15))
                    )
            }

            // Initiator / document URL
            if event.initiator != nil || event.documentUrl != nil {
                SectionHeader(title: "Origin") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let initiator = event.initiator {
                            LabeledField(label: "Initiator", value: initiator)
                        }
                        if let docUrl = event.documentUrl {
                            LabeledField(label: "Document", value: docUrl)
                        }
                    }
                }
            }

            // Request headers
            if let headers = event.requestHeaders, !headers.isEmpty {
                let table = HeadersTable(headers: headers)
                SectionHeader(title: "Request Headers", copyText: table.headersAsText) {
                    table
                }
            }

            // POST data
            if let postData = event.postData, !postData.isEmpty {
                SectionHeader(title: "Request Body", copyText: postData) {
                    SyntaxTextView(
                        text: postData,
                        mimeHint: contentTypeFromHeaders(event.requestHeaders)
                    )
                }
            }

            if event.requestHeaders == nil && event.postData == nil
                && event.initiator == nil && event.documentUrl == nil {
                emptyPlaceholder("No request details captured.")
            }
        }
        .padding(12)
    }
}

// MARK: - Response Detail

private struct ResponseDetailView: View {
    let event: TraceEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Status
            if let code = event.statusCode {
                HStack(spacing: 8) {
                    StatusBadge(statusCode: code, errorText: event.errorText)
                    Text(HTTPStatusReason.reason(for: code))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            // Error
            if let errorText = event.errorText {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                    Text(errorText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Response headers
            if let headers = event.responseHeaders, !headers.isEmpty {
                let table = HeadersTable(headers: headers)
                SectionHeader(title: "Response Headers", copyText: table.headersAsText) {
                    table
                }
            }

            // Response body
            if let body = event.responseBody, !body.isEmpty {
                SectionHeader(title: "Response Body", copyText: body) {
                    VStack(alignment: .leading, spacing: 4) {
                        if event.responseBodyTruncated == true {
                            HStack(spacing: 4) {
                                Image(systemName: "scissors")
                                    .font(.system(size: 9))
                                Text("Response body was truncated")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.orange)
                        }
                        SyntaxTextView(text: body, mimeHint: event.mimeType)
                    }
                }
            }

            if event.responseHeaders == nil && event.responseBody == nil && event.errorText == nil {
                emptyPlaceholder("No response captured.")
            }
        }
        .padding(12)
    }
}

// MARK: - Form Fields Detail

private struct FormFieldsDetailView: View {
    let event: TraceEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let fields = event.formFields, !fields.isEmpty {
                SectionHeader(title: "Captured Form Fields") {
                    formFieldsTable(fields)
                }

                // Comparison with POST data
                if let postData = event.postData, !postData.isEmpty {
                    Divider().padding(.vertical, 4)
                    SectionHeader(title: "POST Data vs Form Values") {
                        comparisonView(fields: fields, postData: postData)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        .font(.system(size: 24))
                        .foregroundStyle(.quaternary)
                    Text("No form fields captured for this request.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Form field snapshots are recorded when a form is submitted.")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }
        }
        .padding(12)
    }

    private func formFieldsTable(_ fields: [TraceEvent.FormFieldSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // Header
            HStack(spacing: 0) {
                Text("Field Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Type")
                    .frame(width: 70, alignment: .center)
                Text("Value")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        if field.type.lowercased() == "password" {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        }
                        Text(field.name)
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(field.type)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .center)

                    Text(field.type.lowercased() == "password" ? String(repeating: "\u{2022}", count: field.value.count) : field.value)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(index % 2 == 0 ? Color.clear : Color.primary.opacity(0.02))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.2))
        )
    }

    private func comparisonView(fields: [TraceEvent.FormFieldSnapshot], postData: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This section compares the form field values at capture time with the actual POST data sent. Differences may indicate client-side transformation (e.g., hashing, encoding).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            let postParams = parsePostParams(postData)

            ForEach(fields, id: \.name) { field in
                let sentValue = postParams[field.name]
                let matches = sentValue == field.value
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        if field.type.lowercased() == "password" {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        }
                        Text(field.name)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .frame(width: 100, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Form:")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                            Text(field.value)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                        HStack(spacing: 4) {
                            Text("Sent:")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                            Text(sentValue ?? "(not found)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(sentValue == nil ? .quaternary : .primary)
                        }
                    }

                    Spacer()

                    if let _ = sentValue {
                        Image(systemName: matches ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(matches ? .green : .orange)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.15))
        )
    }

    private func parsePostParams(_ data: String) -> [String: String] {
        // Try URL-encoded form data first
        var params: [String: String] = [:]
        let pairs = data.split(separator: "&")
        for pair in pairs {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count >= 1 else { continue }
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            params[key] = value
        }
        if !params.isEmpty { return params }

        // Try JSON
        if let jsonData = data.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            for (k, v) in obj {
                params[k] = "\(v)"
            }
        }
        return params
    }
}

// MARK: - Navigation Detail

private struct NavigationDetailView: View {
    let event: TraceEvent
    let allEvents: [TraceEvent]
    let baseTimestamp: Double

    private var tabEvents: [TraceEvent] {
        guard let tabId = event.tabId else { return [event] }
        return allEvents
            .filter { $0.tabId == tabId }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private struct NavNode: Identifiable {
        let id: String
        let event: TraceEvent
        let isDocument: Bool
        var children: [NavNode]
    }

    private var navTree: [NavNode] {
        let events = tabEvents
        var documents: [NavNode] = []
        var currentDoc: NavNode?

        for ev in events {
            let isNav = ev.method.uppercased() == "NAVIGATE"
                || ev.navType != nil
                || (ev.mimeType?.contains("html") == true && ev.documentUrl == nil)
                || ev.documentUrl == nil
                || ev.documentUrl == ev.url

            if isNav && (ev.mimeType?.contains("html") == true || ev.method.uppercased() == "NAVIGATE" || ev.navType != nil) {
                if let doc = currentDoc { documents.append(doc) }
                currentDoc = NavNode(id: ev.id, event: ev, isDocument: true, children: [])
            } else if var doc = currentDoc {
                doc.children.append(NavNode(id: ev.id, event: ev, isDocument: false, children: []))
                currentDoc = doc
            } else {
                // Sub-resource before any document
                documents.append(NavNode(id: ev.id, event: ev, isDocument: false, children: []))
            }
        }
        if let doc = currentDoc { documents.append(doc) }
        return documents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tabId = event.tabId {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(verbatim: "Tab \(tabId)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\u{2014} \(tabEvents.count) events")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
                .padding(.bottom, 4)
            }

            // Navigation flow summary
            let docEvents = tabEvents.filter {
                $0.method.uppercased() == "NAVIGATE" || $0.navType != nil
                    || ($0.mimeType?.contains("html") == true && ($0.documentUrl == nil || $0.documentUrl == $0.url))
            }
            if docEvents.count > 1 {
                SectionHeader(title: "Navigation Flow") {
                    flowView(docEvents)
                }
                .padding(.bottom, 6)
            }

            // Tree
            SectionHeader(title: "Request Tree") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(navTree) { node in
                        navNodeRow(node, depth: 0, isHighlighted: node.id == event.id)
                        ForEach(node.children) { child in
                            navNodeRow(child, depth: 1, isHighlighted: child.id == event.id)
                        }
                    }
                }
            }

            if event.tabId == nil {
                emptyPlaceholder("No tab ID available for navigation tracking.")
            }
        }
        .padding(12)
    }

    private func flowView(_ docs: [TraceEvent]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(docs.enumerated()), id: \.element.id) { index, doc in
                    flowNode(doc: doc)
                    if index < docs.count - 1 {
                        flowArrow(nextDoc: docs[index + 1])
                    }
                }
            }
            .padding(4)
        }
    }

    private func flowNode(doc: TraceEvent) -> some View {
        let path = URL(string: doc.url)?.path ?? doc.url
        let isCurrent = doc.id == event.id
        return VStack(spacing: 2) {
            Text(truncatePath(path, maxLen: 28))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                .lineLimit(1)
            if let navType = doc.navType {
                Text(navType)
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isCurrent ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03))
        )
    }

    private func flowArrow(nextDoc: TraceEvent) -> some View {
        HStack(spacing: 2) {
            Rectangle()
                .fill(.quaternary)
                .frame(width: 16, height: 1)
            if nextDoc.redirectFrom != nil {
                Text("redirect")
                    .font(.system(size: 7))
                    .foregroundStyle(.orange)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 7))
                .foregroundStyle(.quaternary)
        }
    }

    private func navNodeRow(_ node: NavNode, depth: Int, isHighlighted: Bool) -> some View {
        HStack(spacing: 4) {
            // Indent with connecting line
            if depth > 0 {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1, height: 16)
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 10, height: 1)
                }
                .frame(width: 20)
            }

            if node.isDocument {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 9))
                    .foregroundStyle(.purple)
            } else {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
            }

            MethodBadge(method: node.event.method)

            Text(truncatePath(URL(string: node.event.url)?.path ?? node.event.url, maxLen: 36))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.primary)
                .lineLimit(1)

            Spacer()

            if let code = node.event.statusCode {
                Text("\(code)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(statusColorFor(code))
            }

            if let d = node.event.duration {
                Text(d < 1 ? String(format: "%.0fms", d * 1000) : String(format: "%.2fs", d))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    private func truncatePath(_ path: String, maxLen: Int) -> String {
        if path.count <= maxLen { return path }
        let half = (maxLen - 1) / 2
        return String(path.prefix(half)) + "\u{2026}" + String(path.suffix(half))
    }

    private func statusColorFor(_ code: Int) -> Color {
        switch code {
        case 200...299: .green
        case 300...399: .yellow
        case 400...499: .orange
        case 500...599: .red
        default: .gray
        }
    }
}

// MARK: - Timing Detail

private struct TimingDetailView: View {
    let event: TraceEvent
    let baseTimestamp: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TimingRow(label: "Request Time", value: String(format: "+%.3fs from session start", event.timestamp - baseTimestamp))

            TimingRow(label: "Absolute Time", value: absoluteTimeString)

            if let duration = event.duration {
                TimingRow(label: "Duration", value: formatDuration(duration))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Duration")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(durationColor(duration).opacity(0.7))
                            .frame(width: max(geo.size.width * min(duration / 2.0, 1.0), 4))
                    }
                    .frame(height: 12)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary.opacity(0.3))
                    )
                }

                TimingRow(
                    label: "Completed At",
                    value: String(format: "+%.3fs from session start", event.timestamp - baseTimestamp + duration)
                )
            } else {
                TimingRow(label: "Duration", value: "Unknown")
            }

            if let tabId = event.tabId {
                TimingRow(label: "Tab ID", value: "\(tabId)")
            }
        }
        .padding(12)
    }

    private var absoluteTimeString: String {
        let date = Date(timeIntervalSince1970: event.timestamp)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt.string(from: date)
    }

    private func formatDuration(_ d: Double) -> String {
        if d < 0.001 { return String(format: "%.0f \u{00b5}s", d * 1_000_000) }
        if d < 1 { return String(format: "%.1f ms", d * 1000) }
        return String(format: "%.3f s", d)
    }

    private func durationColor(_ d: Double) -> Color {
        if d < 0.1 { return .green }
        if d < 0.5 { return .yellow }
        if d < 1.0 { return .orange }
        return .red
    }
}

private struct TimingRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Labeled Field

private struct LabeledField: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Utility

private func emptyPlaceholder(_ message: String) -> some View {
    Text(message)
        .font(.system(size: 11))
        .foregroundStyle(.quaternary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 40)
}

private func contentTypeFromHeaders(_ headers: [String: String]?) -> String? {
    guard let headers else { return nil }
    return headers.first { $0.key.lowercased() == "content-type" }?.value
}

// MARK: - HTTP Status Reasons

private enum HTTPStatusReason {
    static func reason(for code: Int) -> String {
        switch code {
        case 100: "Continue"
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 413: "Payload Too Large"
        case 422: "Unprocessable Entity"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: ""
        }
    }
}
