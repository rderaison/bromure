import Foundation

enum TabStripGeometry {
    static let minimumWidth: CGFloat = 120
    static let maximumWidth: CGFloat = 240
    static let pinnedWidth: CGFloat = 36
    static let gap: CGFloat = 4
    static let hysteresis: CGFloat = 10
    static func restingWidths(available: CGFloat, count: Int, selectedIndex: Int, activeIsEmpty: Bool = true) -> [CGFloat] {
        guard count > 0 else { return [] }
        if count == 1 { return [min(280, max(minimumWidth, available))] }
        if count == 2 && activeIsEmpty {
            // The 192pt neighbor in the recording reflects its available room.
            // Let that neighbor grow to the normal tab maximum in wider rows.
            let total = min(maximumWidth + 280, max(2 * minimumWidth, available))
            let active = min(280, total - minimumWidth)
            return (0..<2).map { $0 == selectedIndex ? active : total - active }
        }
        if count == 2 {
            let neighbor = min(maximumWidth, max(minimumWidth, available / 2))
            let active = min(280, max(neighbor, available - neighbor))
            return (0..<2).map { $0 == selectedIndex ? active : neighbor }
        }
        return Array(repeating: width(available: available, count: count), count: count)
    }
    static func destination(center: CGFloat, slot: Int, frames: [CGRect]) -> Int {
        guard !frames.isEmpty else { return 0 }
        var result = min(frames.count - 1, max(0, slot))
        // Choose the nearer slot as soon as the dragged center crosses the
        // halfway boundary, rather than requiring a full slot of travel.
        while result + 1 < frames.count && center > (frames[result].midX + frames[result + 1].midX) / 2 + hysteresis { result += 1 }
        while result > 0 && center < (frames[result - 1].midX + frames[result].midX) / 2 - hysteresis { result -= 1 }
        return result
    }
    static func width(available: CGFloat, count: Int) -> CGFloat {
        let count = max(1, count)
        return min(maximumWidth, max(minimumWidth, (available - CGFloat(count - 1) * gap) / CGFloat(count)))
    }
    static func x(_ index: Int, width: CGFloat) -> CGFloat { CGFloat(index) * (width + gap) }
    static func extent(width: CGFloat, count: Int) -> CGFloat { max(0, CGFloat(count) * width + CGFloat(count - 1) * gap) }
    static func nearestSlot(center: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count - 1, max(0, Int(((center - width / 2) / (width + gap)).rounded())))
    }
    static func destination(center: CGFloat, slot: Int, width: CGFloat, remainingCount: Int) -> Int {
        let frames = (0...max(0, remainingCount)).map { index in
            CGRect(x: x(index, width: width), y: 0, width: width, height: 36)
        }
        return destination(center: center, slot: slot, frames: frames)
    }
}
