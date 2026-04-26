import AppKit
import SandboxEngine
import SwiftUI

// MARK: - Data Model

/// A building on the isometric floor plan. Each represents a page navigation.
struct IsoBuilding: Identifiable {
    let id: String
    let url: String
    let hostname: String
    let displayLabel: String
    let timestamp: Double
    let navType: String?
    let statusCode: Int?
    let method: String
    let subRequests: [TraceEvent]
    let isStart: Bool
    let gridX: Int
    let gridY: Int

    /// Building height proportional to sub-request count (1-8 floors)
    var floors: Int {
        let count = subRequests.count
        if count == 0 { return 1 }
        if count <= 3 { return 2 }
        if count <= 10 { return 3 }
        if count <= 25 { return 4 }
        if count <= 50 { return 5 }
        if count <= 100 { return 6 }
        if count <= 200 { return 7 }
        return 8
    }

    /// Base color
    var color: Color {
        if isStart { return .green }
        let sc = statusCode ?? 0
        if sc >= 400 { return .red }
        if navType == "redirect" || (sc >= 300 && sc < 400) { return .purple }
        if navType == "form_submit" || method.uppercased() == "POST" { return .orange }
        return .blue
    }
}

struct IsoConnection {
    let fromX: Int
    let fromY: Int
    let toX: Int
    let toY: Int
    let label: String
    let isRedirect: Bool
}

/// Build isometric layout from trace events.
struct IsoLayout {
    let buildings: [IsoBuilding]
    let connections: [IsoConnection]

    static func build(from events: [TraceEvent], tabId: Int? = nil) -> IsoLayout {
        let tabEvents: [TraceEvent]
        if let tabId {
            tabEvents = events.filter { $0.tabId == tabId }.sorted { $0.timestamp < $1.timestamp }
        } else {
            tabEvents = events.sorted { $0.timestamp < $1.timestamp }
        }

        let navTypes: Set<String> = [
            "main_frame", "redirect", "link", "typed",
            "form_submit", "reload", "back_forward",
        ]
        var navigations: [TraceEvent] = []
        var subRequests: [TraceEvent] = []

        for ev in tabEvents {
            let isNav = ev.method.uppercased() == "NAVIGATE"
                || navTypes.contains(ev.navType ?? "")
                || (ev.mimeType?.contains("html") == true
                    && (ev.documentUrl == nil || ev.documentUrl == ev.url))
            if isNav { navigations.append(ev) }
            else { subRequests.append(ev) }
        }

        if navigations.isEmpty && !subRequests.isEmpty {
            let first = subRequests.first!
            let host = first.hostname ?? URLComponents(string: first.url)?.host ?? ""
            let b = IsoBuilding(
                id: "root", url: first.documentUrl ?? first.url,
                hostname: host, displayLabel: host,
                timestamp: first.timestamp, navType: nil, statusCode: nil,
                method: "GET", subRequests: subRequests, isStart: true,
                gridX: 0, gridY: 0
            )
            return IsoLayout(buildings: [b], connections: [])
        }

        // Place buildings on a grid using a zigzag pattern
        // Redirects go sideways (same Y, X+1), regular navigations go forward (Y+1)
        var buildings: [IsoBuilding] = []
        var connections: [IsoConnection] = []
        var curX = 0
        var curY = 0

        for (i, nav) in navigations.enumerated() {
            let nextTs = (i + 1 < navigations.count) ? navigations[i + 1].timestamp : Double.greatestFiniteMagnitude
            let subs = subRequests.filter { $0.timestamp >= nav.timestamp && $0.timestamp < nextTs }
            let hostname = nav.hostname ?? URLComponents(string: nav.url)?.host ?? ""
            let path = URL(string: nav.url)?.path ?? nav.url
            var label = (path.isEmpty || path == "/") ? hostname : "\(hostname)\(path)"
            if label.count > 30 { label = String(label.prefix(27)) + "\u{2026}" }

            let isRedirect = nav.navType == "redirect" || ((nav.statusCode ?? 0) >= 300 && (nav.statusCode ?? 0) < 400)

            if i > 0 {
                let prevX = buildings[i - 1].gridX
                let prevY = buildings[i - 1].gridY
                if isRedirect {
                    curX = prevX + 1  // redirect: move sideways
                    curY = prevY
                } else if nav.navType == "back_forward" {
                    curX = prevX - 1  // back: move left
                    curY = prevY + 1
                } else {
                    curX = prevX      // forward: move down
                    curY = prevY + 1
                }
                connections.append(IsoConnection(
                    fromX: prevX, fromY: prevY, toX: curX, toY: curY,
                    label: nav.navType ?? "\u{2192}",
                    isRedirect: isRedirect
                ))
            }

            buildings.append(IsoBuilding(
                id: nav.id, url: nav.url, hostname: hostname,
                displayLabel: label, timestamp: nav.timestamp,
                navType: nav.navType, statusCode: nav.statusCode,
                method: nav.method.isEmpty ? "GET" : nav.method,
                subRequests: subs, isStart: i == 0,
                gridX: curX, gridY: curY
            ))
        }

        return IsoLayout(buildings: buildings, connections: connections)
    }
}

// MARK: - Isometric Projection

private struct IsoProjection {
    let tileWidth: CGFloat = 120
    let tileHeight: CGFloat = 60
    let floorHeight: CGFloat = 14

    /// Convert grid coordinates to screen coordinates (isometric)
    func toScreen(gridX: Int, gridY: Int, z: CGFloat = 0) -> CGPoint {
        let x = CGFloat(gridX - gridY) * tileWidth / 2
        let y = CGFloat(gridX + gridY) * tileHeight / 2 - z
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Window

func showFlowGraphWindow(events: [TraceEvent], sessionName: String, onPin: ((String) -> Void)? = nil) {
    let tabIds = Set(events.compactMap(\.tabId)).sorted()

    let view = IsoFlowView(
        events: events,
        sessionName: sessionName,
        tabIds: tabIds,
        initialTab: tabIds.first,
        onPin: onPin
    )

    let hostView = NSHostingView(rootView: view)
    hostView.setFrameSize(NSSize(width: 1000, height: 700))

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Flow \u{2014} \(sessionName)"
    window.contentView = hostView
    window.contentMinSize = NSSize(width: 600, height: 400)
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.isReleasedWhenClosed = false
}

// MARK: - Main View

private struct IsoFlowView: View {
    let events: [TraceEvent]
    let sessionName: String
    let tabIds: [Int]
    let initialTab: Int?
    /// Called when user pins a building — passes the page URL for filtering in the trace viewer.
    var onPin: ((String) -> Void)?

    @State private var selectedTab: Int?
    @State private var selectedBuilding: String?
    @State private var pinnedBuildings: Set<String> = []
    @State private var searchText = ""
    @State private var offset: CGSize = .zero
    @State private var zoom: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            let layout = IsoLayout.build(from: events, tabId: selectedTab ?? initialTab)

            if layout.buildings.isEmpty {
                Text("No navigation events captured")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    // Dark floor
                    Color(nsColor: NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1))

                    // Isometric canvas
                    IsoCanvas(
                        layout: layout,
                        selectedBuilding: $selectedBuilding,
                        pinnedBuildings: pinnedBuildings,
                        searchText: searchText,
                        offset: offset,
                        zoom: zoom
                    )
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: offset.width + value.translation.width,
                                height: offset.height + value.translation.height
                            )
                        }
                )
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            zoom = max(0.3, min(3.0, zoom * value.magnification))
                        }
                )
                .onTapGesture {
                    selectedBuilding = nil
                }
            }

            // Selected building detail panel
            if let bid = selectedBuilding, let building = layout.buildings.first(where: { $0.id == bid }) {
                Divider()
                buildingDetailPanel(building)
                    .frame(height: 200)
            }
        }
        .onAppear { selectedTab = initialTab }
        .onKeyPress(.escape) {
            selectedBuilding = nil
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigateBuilding(layout: IsoLayout.build(from: events, tabId: selectedTab ?? initialTab), direction: .right)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            navigateBuilding(layout: IsoLayout.build(from: events, tabId: selectedTab ?? initialTab), direction: .left)
            return .handled
        }
        .onKeyPress(.downArrow) {
            navigateBuilding(layout: IsoLayout.build(from: events, tabId: selectedTab ?? initialTab), direction: .down)
            return .handled
        }
        .onKeyPress(.upArrow) {
            navigateBuilding(layout: IsoLayout.build(from: events, tabId: selectedTab ?? initialTab), direction: .up)
            return .handled
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Tab selector
            if tabIds.count > 1 {
                ForEach(tabIds, id: \.self) { tabId in
                    Button { selectedTab = tabId } label: {
                        Text(verbatim: "Tab \(tabId)")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (selectedTab ?? initialTab) == tabId
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.primary.opacity(0.05)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
                Divider().frame(height: 14)
            }

            // Search
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Filter pages\u{2026}", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 150)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Spacer()

            // Home button — reset pan/zoom
            Button {
                offset = .zero
                zoom = 1.0
            } label: {
                Image(systemName: "house")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Reset view to center")
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Divider().frame(height: 14)

            // Legend
            HStack(spacing: 8) {
                legendItem(color: .green, label: "Entry")
                legendItem(color: .blue, label: "GET")
                legendItem(color: .orange, label: "POST")
                legendItem(color: .purple, label: "Redirect")
                legendItem(color: .red, label: "Error")
            }
            .font(.system(size: 9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private enum NavDirection { case left, right, up, down }

    private func navigateBuilding(layout: IsoLayout, direction: NavDirection) {
        guard !layout.buildings.isEmpty else { return }

        // If nothing selected, select the first building
        guard let currentId = selectedBuilding,
              let currentIdx = layout.buildings.firstIndex(where: { $0.id == currentId }) else {
            selectedBuilding = layout.buildings.first?.id
            return
        }

        // Navigate based on direction in the ordered list
        switch direction {
        case .right, .down:
            let next = (currentIdx + 1) % layout.buildings.count
            selectedBuilding = layout.buildings[next].id
        case .left, .up:
            let prev = (currentIdx - 1 + layout.buildings.count) % layout.buildings.count
            selectedBuilding = layout.buildings[prev].id
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color.opacity(0.8))
                .frame(width: 10, height: 8)
            Text(label).foregroundStyle(.secondary)
        }
    }

    // MARK: - Building Detail Panel

    private func buildingDetailPanel(_ b: IsoBuilding) -> some View {
        HStack(spacing: 0) {
            // Left: page info
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(b.color)
                        .frame(width: 14, height: 14)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.displayLabel)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(b.hostname)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let sc = b.statusCode, sc > 0 {
                        Text(verbatim: "\(sc)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(statusColor(sc))
                    }

                    if b.navType == "form_submit" {
                        Text("POST")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 3))
                    }

                    if let nt = b.navType, nt != "form_submit" {
                        Text(nt)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                HStack {
                    Text(b.url)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Spacer()

                    Button {
                        if pinnedBuildings.contains(b.id) {
                            pinnedBuildings.remove(b.id)
                        } else {
                            pinnedBuildings.insert(b.id)
                            onPin?(b.url)
                        }
                    } label: {
                        Image(systemName: pinnedBuildings.contains(b.id) ? "pin.fill" : "pin")
                            .font(.system(size: 12))
                            .foregroundStyle(pinnedBuildings.contains(b.id) ? .red : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(pinnedBuildings.contains(b.id) ? "Unpin this page" : "Pin — find in trace viewer")
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(verbatim: "\(b.subRequests.count) sub-requests")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(verbatim: "\u{2022} \(b.floors) floors")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                    if b.isStart {
                        Text("\u{25B6} Entry point")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(10)
            .frame(width: 350)

            Divider()

            // Right: sub-request list
            VStack(alignment: .leading, spacing: 0) {
                Text("Sub-requests")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                if b.subRequests.isEmpty {
                    Text("No sub-requests")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(b.subRequests) { req in
                                HStack(spacing: 6) {
                                    Text(req.method)
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(methodColor(req.method))
                                        .frame(width: 32, alignment: .trailing)

                                    Text(verbatim: "\(req.statusCode ?? 0)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(statusColor(req.statusCode ?? 0))
                                        .frame(width: 24)

                                    Text(req.url.components(separatedBy: "?").first ?? req.url)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.primary.opacity(0.8))
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Spacer()

                                    if let dur = req.duration {
                                        Text(String(format: "%.0fms", dur))
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundStyle(.quaternary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(b.subRequests.firstIndex(where: { $0.id == req.id })! % 2 == 0
                                    ? Color.clear : Color.primary.opacity(0.03))
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return .blue
        case "POST": return .orange
        case "PUT": return .yellow
        case "DELETE": return .red
        default: return .secondary
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .purple
        case 400..<500: return .red
        case 500..<600: return .red
        default: return .gray
        }
    }
}

// MARK: - Isometric Canvas

private struct IsoCanvas: View {
    let layout: IsoLayout
    @Binding var selectedBuilding: String?
    let pinnedBuildings: Set<String>
    let searchText: String
    let offset: CGSize
    let zoom: CGFloat

    private let iso = IsoProjection()

    var body: some View {
        Canvas { context, size in
            // Center the view
            let centerX = size.width / 2 + offset.width
            let centerY = size.height / 3 + offset.height

            var ctx = context
            ctx.translateBy(x: centerX, y: centerY)
            ctx.scaleBy(x: zoom, y: zoom)

            // Draw grid floor
            drawGrid(&ctx, buildings: layout.buildings)

            // Draw connections (on the floor)
            for conn in layout.connections {
                drawConnection(&ctx, conn: conn)
            }

            // Sort buildings for correct draw order (back to front)
            let sorted = layout.buildings.sorted { ($0.gridX + $0.gridY) < ($1.gridX + $1.gridY) }

            // Draw buildings
            for building in sorted {
                let isSelected = building.id == selectedBuilding
                let isSearchMatch = !searchText.isEmpty
                    && (building.url.localizedCaseInsensitiveContains(searchText)
                        || building.hostname.localizedCaseInsensitiveContains(searchText))
                let isDimmed = !searchText.isEmpty && !isSearchMatch

                let isPinned = pinnedBuildings.contains(building.id)
                drawBuilding(&ctx, building: building, isSelected: isSelected, isDimmed: isDimmed, isHighlighted: isSearchMatch, isPinned: isPinned)

                // Sub-request particles around the building
                drawSubRequestParticles(&ctx, building: building, isDimmed: isDimmed)
            }
        }
        .overlay {
            // Invisible hit-test layer using GeometryReader to get the actual size
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { location in
                        let cx = geo.size.width / 2 + offset.width
                        let cy = geo.size.height / 3 + offset.height
                        // Reverse the transform: screen → canvas coordinates
                        let canvasX = (location.x - cx) / zoom
                        let canvasY = (location.y - cy) / zoom

                        // Find the closest building
                        var best: (id: String, dist: CGFloat)? = nil
                        for building in layout.buildings {
                            let screen = iso.toScreen(gridX: building.gridX, gridY: building.gridY)
                            let dx = canvasX - screen.x
                            let dy = canvasY - screen.y + CGFloat(building.floors) * iso.floorHeight / 2
                            let dist = sqrt(dx * dx + dy * dy)
                            if dist < 50, best == nil || dist < best!.dist {
                                best = (id: building.id, dist: CGFloat(dist))
                            }
                        }
                        selectedBuilding = best?.id
                    }
            }
        }
    }

    // MARK: - Drawing

    private func drawGrid(_ ctx: inout GraphicsContext, buildings: [IsoBuilding]) {
        let minX = (buildings.map(\.gridX).min() ?? 0) - 2
        let maxX = (buildings.map(\.gridX).max() ?? 0) + 2
        let minY = (buildings.map(\.gridY).min() ?? 0) - 2
        let maxY = (buildings.map(\.gridY).max() ?? 0) + 2

        for gx in minX...maxX {
            for gy in minY...maxY {
                let tl = iso.toScreen(gridX: gx, gridY: gy)
                let tr = iso.toScreen(gridX: gx + 1, gridY: gy)
                let br = iso.toScreen(gridX: gx + 1, gridY: gy + 1)
                let bl = iso.toScreen(gridX: gx, gridY: gy + 1)

                var path = Path()
                path.move(to: tl)
                path.addLine(to: tr)
                path.addLine(to: br)
                path.addLine(to: bl)
                path.closeSubpath()

                ctx.stroke(path, with: .color(.white.opacity(0.03)), lineWidth: 0.5)
            }
        }
    }

    private func drawConnection(_ ctx: inout GraphicsContext, conn: IsoConnection) {
        let from = iso.toScreen(gridX: conn.fromX, gridY: conn.fromY)
        let to = iso.toScreen(gridX: conn.toX, gridY: conn.toY)

        var path = Path()
        path.move(to: from)
        path.addLine(to: to)

        let color: Color = conn.isRedirect ? .purple : .cyan
        ctx.stroke(
            path,
            with: .color(color.opacity(0.4)),
            style: StrokeStyle(lineWidth: 2, dash: conn.isRedirect ? [6, 4] : [])
        )

        // Arrow head
        let angle = atan2(to.y - from.y, to.x - from.x)
        let arrowLen: CGFloat = 8
        let arrowAngle: CGFloat = .pi / 6
        var arrow = Path()
        arrow.move(to: to)
        arrow.addLine(to: CGPoint(
            x: to.x - arrowLen * cos(angle - arrowAngle),
            y: to.y - arrowLen * sin(angle - arrowAngle)
        ))
        arrow.move(to: to)
        arrow.addLine(to: CGPoint(
            x: to.x - arrowLen * cos(angle + arrowAngle),
            y: to.y - arrowLen * sin(angle + arrowAngle)
        ))
        ctx.stroke(arrow, with: .color(color.opacity(0.6)), lineWidth: 1.5)
    }

    private func drawBuilding(_ ctx: inout GraphicsContext, building: IsoBuilding, isSelected: Bool, isDimmed: Bool, isHighlighted: Bool, isPinned: Bool) {
        let base = iso.toScreen(gridX: building.gridX, gridY: building.gridY)
        let h = CGFloat(building.floors) * iso.floorHeight
        let w = iso.tileWidth * 0.7
        let d = iso.tileHeight * 0.7

        let alpha: CGFloat = isDimmed ? 0.15 : 1.0

        // Isometric box vertices
        // Top face
        let topTL = CGPoint(x: base.x, y: base.y - h)
        let topTR = CGPoint(x: base.x + w / 2, y: base.y - d / 2 - h)
        let topBR = CGPoint(x: base.x, y: base.y - d - h)
        let topBL = CGPoint(x: base.x - w / 2, y: base.y - d / 2 - h)

        // Bottom face
        let botTL = CGPoint(x: base.x, y: base.y)
        let botTR = CGPoint(x: base.x + w / 2, y: base.y - d / 2)
        let botBR = CGPoint(x: base.x, y: base.y - d)
        let botBL = CGPoint(x: base.x - w / 2, y: base.y - d / 2)

        let baseColor = building.color

        // Shadow on the floor
        var shadowPath = Path()
        shadowPath.move(to: CGPoint(x: botTL.x + 4, y: botTL.y + 3))
        shadowPath.addLine(to: CGPoint(x: botTR.x + 4, y: botTR.y + 3))
        shadowPath.addLine(to: CGPoint(x: botBR.x + 4, y: botBR.y + 3))
        shadowPath.addLine(to: CGPoint(x: botBL.x + 4, y: botBL.y + 3))
        shadowPath.closeSubpath()
        ctx.fill(shadowPath, with: .color(.black.opacity(0.3 * alpha)))

        // Right face (lighter shade)
        var rightFace = Path()
        rightFace.move(to: botTL)
        rightFace.addLine(to: botTR)
        rightFace.addLine(to: topTR)
        rightFace.addLine(to: topTL)
        rightFace.closeSubpath()
        ctx.fill(rightFace, with: .color(baseColor.opacity(0.6 * alpha)))
        ctx.stroke(rightFace, with: .color(.black.opacity(0.15 * alpha)), lineWidth: 0.5)

        // Left face (darker shade)
        var leftFace = Path()
        leftFace.move(to: botTL)
        leftFace.addLine(to: botBL)
        leftFace.addLine(to: topBL)
        leftFace.addLine(to: topTL)
        leftFace.closeSubpath()
        ctx.fill(leftFace, with: .color(baseColor.opacity(0.4 * alpha)))
        ctx.stroke(leftFace, with: .color(.black.opacity(0.15 * alpha)), lineWidth: 0.5)

        // Top face (brightest)
        var topFace = Path()
        topFace.move(to: topTL)
        topFace.addLine(to: topTR)
        topFace.addLine(to: topBR)
        topFace.addLine(to: topBL)
        topFace.closeSubpath()
        ctx.fill(topFace, with: .color(baseColor.opacity(0.85 * alpha)))
        ctx.stroke(topFace, with: .color(.white.opacity(0.2 * alpha)), lineWidth: 0.5)

        // Floor lines on the front faces (like building windows)
        for floor in 1..<building.floors {
            let fh = CGFloat(floor) * iso.floorHeight
            let lineAlpha = 0.15 * alpha

            // Right face floor line
            var rLine = Path()
            rLine.move(to: CGPoint(x: botTL.x, y: botTL.y - fh))
            rLine.addLine(to: CGPoint(x: botTR.x, y: botTR.y - fh))
            ctx.stroke(rLine, with: .color(.white.opacity(lineAlpha)), lineWidth: 0.5)

            // Left face floor line
            var lLine = Path()
            lLine.move(to: CGPoint(x: botTL.x, y: botTL.y - fh))
            lLine.addLine(to: CGPoint(x: botBL.x, y: botBL.y - fh))
            ctx.stroke(lLine, with: .color(.white.opacity(lineAlpha)), lineWidth: 0.5)
        }

        // Selection glow
        if isSelected {
            var outline = Path()
            outline.move(to: topTL)
            outline.addLine(to: topTR)
            outline.addLine(to: botTR)
            outline.addLine(to: botTL)
            outline.addLine(to: botBL)
            outline.addLine(to: topBL)
            outline.closeSubpath()
            ctx.stroke(outline, with: .color(.white.opacity(0.8)), lineWidth: 2)
        }

        // Search highlight glow
        if isHighlighted {
            var outline = Path()
            outline.move(to: topTL)
            outline.addLine(to: topTR)
            outline.addLine(to: botTR)
            outline.addLine(to: botTL)
            outline.addLine(to: botBL)
            outline.addLine(to: topBL)
            outline.closeSubpath()
            ctx.stroke(outline, with: .color(.yellow.opacity(0.9)), lineWidth: 2.5)
        }

        // Label on top
        if !isDimmed {
            let labelText = Text(building.displayLabel)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
            ctx.draw(
                ctx.resolve(labelText),
                at: CGPoint(x: topTL.x, y: topTL.y - 10),
                anchor: .bottom
            )

            // Sub-request count badge
            if !building.subRequests.isEmpty {
                let badge = Text(verbatim: "\(building.subRequests.count)")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                ctx.draw(
                    ctx.resolve(badge),
                    at: CGPoint(x: topTL.x, y: topTL.y - 1),
                    anchor: .bottom
                )
            }

            // POST badge
            if building.method.uppercased() == "POST" || building.navType == "form_submit" {
                let postBadge = Text("POST")
                    .font(.system(size: 6, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.orange)
                ctx.draw(
                    ctx.resolve(postBadge),
                    at: CGPoint(x: topTR.x + 2, y: topTR.y),
                    anchor: .leading
                )
            }

            // Start marker
            if building.isStart {
                let marker = Text("\u{25B6} START")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.green)
                ctx.draw(
                    ctx.resolve(marker),
                    at: CGPoint(x: topTL.x, y: topTL.y - 20),
                    anchor: .bottom
                )
            }
        }

        // Pin marker — red pin icon above the building
        if isPinned {
            let pinIcon = Text("\u{1F4CD}")
                .font(.system(size: 14))
            ctx.draw(
                ctx.resolve(pinIcon),
                at: CGPoint(x: topTR.x + 8, y: topTL.y - h - 6),
                anchor: .bottom
            )
        }
    }

    private func drawSubRequestParticles(_ ctx: inout GraphicsContext, building: IsoBuilding, isDimmed: Bool) {
        guard !building.subRequests.isEmpty && !isDimmed else { return }
        let base = iso.toScreen(gridX: building.gridX, gridY: building.gridY)
        let alpha: CGFloat = isDimmed ? 0.05 : 0.5

        // Scatter particles around the building base
        for (i, sub) in building.subRequests.prefix(30).enumerated() {
            // Deterministic scatter based on index
            let angle = Double(i) * 2.39996323  // golden angle
            let radius: CGFloat = 20 + CGFloat(i % 5) * 6
            let px = base.x + cos(angle) * radius
            let py = base.y - 15 + sin(angle) * radius * 0.5  // flatten for isometric

            let isExfil = sub.method.uppercased() == "POST" || sub.method.uppercased() == "PUT"
            let particleColor: Color = isExfil ? .orange : mimeColor(sub.mimeType)
            let size: CGFloat = isExfil ? 3.5 : 2

            ctx.fill(
                Path(ellipseIn: CGRect(x: px - size / 2, y: py - size / 2, width: size, height: size)),
                with: .color(particleColor.opacity(alpha))
            )
        }
    }

    private func mimeColor(_ mime: String?) -> Color {
        let m = mime ?? ""
        if m.contains("javascript") { return .yellow }
        if m.contains("css") { return .cyan }
        if m.contains("image") { return .green }
        if m.contains("font") { return .gray }
        if m.contains("json") || m.contains("xml") { return .mint }
        return .secondary
    }
}

