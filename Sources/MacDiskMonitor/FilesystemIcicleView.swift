import AppKit
import Foundation

struct IcicleNode {
    let name: String
    let path: String
    let size: UInt64
    let children: [IcicleNode]
}

final class FilesystemIcicleView: NSView {
    var rootNodes: [IcicleNode] = [] {
        didSet {
            recomputeLayout()
            needsDisplay = true
        }
    }

    private struct NodeRect {
        let node: IcicleNode
        let depth: Int
        let siblingIndex: Int
        let siblingCount: Int
        let rect: NSRect
    }

    private var nodeRects: [NodeRect] = []
    private var hoverIndex: Int?
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recomputeLayout()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newIndex = findDeepestRect(at: point)
        if newIndex != hoverIndex {
            hoverIndex = newIndex
            needsDisplay = true
        }
    }

    override func mouseExited(with _: NSEvent) {
        hoverIndex = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        for (index, item) in nodeRects.enumerated() {
            let color = colorForNode(
                path: item.node.path,
                depth: item.depth,
                siblingIndex: item.siblingIndex,
                siblingCount: item.siblingCount
            )
            color.setFill()
            item.rect.fill()

            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            let border = NSBezierPath(rect: item.rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()

            drawNodeLabel(for: item.node, in: item.rect)

            if index == hoverIndex {
                NSColor.controlAccentColor.setStroke()
                let highlight = item.rect.insetBy(dx: 1.5, dy: 1.5)
                let path = NSBezierPath(rect: highlight)
                path.lineWidth = 2
                path.stroke()
            }
        }

        drawHoverOverlay()
    }

    private func recomputeLayout() {
        guard !bounds.isEmpty else {
            nodeRects = []
            return
        }

        let maxDepth = max(1, depthOf(nodes: rootNodes, currentDepth: 1))
        let rowHeight = bounds.height / CGFloat(maxDepth)
        nodeRects = []
        layout(nodes: rootNodes, within: NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight), depth: 1, rowHeight: rowHeight)
    }

    private func layout(nodes: [IcicleNode], within rowRect: NSRect, depth: Int, rowHeight: CGFloat) {
        guard !nodes.isEmpty else { return }

        let totalSize = max(1, nodes.reduce(UInt64(0)) { $0 + max(1, $1.size) })
        var xCursor = rowRect.minX

        for (index, node) in nodes.enumerated() {
            let weightedSize = max(1, node.size)
            let width: CGFloat = if index == nodes.count - 1 {
                rowRect.maxX - xCursor
            } else {
                rowRect.width * (CGFloat(weightedSize) / CGFloat(totalSize))
            }

            let rect = NSRect(x: xCursor, y: rowRect.minY, width: max(0, width), height: rowHeight)
            nodeRects.append(NodeRect(node: node, depth: depth, siblingIndex: index, siblingCount: nodes.count, rect: rect))

            if !node.children.isEmpty {
                let childRow = NSRect(x: rect.minX, y: rowRect.minY + rowHeight, width: rect.width, height: rowHeight)
                layout(nodes: node.children, within: childRow, depth: depth + 1, rowHeight: rowHeight)
            }

            xCursor += width
        }
    }

    private func depthOf(nodes: [IcicleNode], currentDepth: Int) -> Int {
        guard !nodes.isEmpty else { return currentDepth }

        var best = currentDepth
        for node in nodes where !node.children.isEmpty {
            best = max(best, depthOf(nodes: node.children, currentDepth: currentDepth + 1))
        }
        return best
    }

    private func findDeepestRect(at point: NSPoint) -> Int? {
        for index in nodeRects.indices.reversed() where nodeRects[index].rect.contains(point) {
            return index
        }
        return nil
    }

    private func drawNodeLabel(for node: IcicleNode, in rect: NSRect) {
        guard rect.width > 34, rect.height > 18 else { return }

        let label = node.name
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]

        let text = NSAttributedString(string: label, attributes: attributes)
        let textSize = text.size()
        guard textSize.width <= rect.width - 8 else { return }

        let drawPoint = NSPoint(
            x: rect.midX - (textSize.width / 2),
            y: rect.midY - (textSize.height / 2)
        )
        text.draw(at: drawPoint)
    }

    private func drawHoverOverlay() {
        guard let hoverIndex else { return }

        let node = nodeRects[hoverIndex].node
        let value = "\(node.path) - \(formatBytes(node.size))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = NSAttributedString(string: value, attributes: attributes)
        let textSize = text.size()

        let bubbleWidth = textSize.width + 16
        let bubbleHeight = textSize.height + 10
        let bubbleRect = NSRect(x: 10, y: 10, width: bubbleWidth, height: bubbleHeight)

        NSColor.controlBackgroundColor.withAlphaComponent(0.94).setFill()
        let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 8, yRadius: 8)
        bubble.fill()

        NSColor.separatorColor.setStroke()
        bubble.lineWidth = 1
        bubble.stroke()

        text.draw(at: NSPoint(x: bubbleRect.minX + 8, y: bubbleRect.minY + 5))
    }

    private func colorForNode(path: String, depth: Int, siblingIndex: Int, siblingCount: Int) -> NSColor {
        let hue: CGFloat
        if depth == 1 {
            hue = topRowHue(index: siblingIndex, total: siblingCount)
        } else {
            let hash = UInt(bitPattern: path.hashValue)
            hue = CGFloat(hash % 360) / 360.0
        }

        let saturation = max(0.25, 0.58 - CGFloat(depth) * 0.06)
        let brightness = min(0.93, 0.82 + CGFloat(depth) * 0.04)
        return NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private func topRowHue(index: Int, total _: Int) -> CGFloat {
        // Intentionally arranged to maximize contrast between adjacent top-level boxes.
        let sequence: [CGFloat] = [0.02, 0.56, 0.14, 0.72, 0.29, 0.84, 0.42, 0.95]
        let base = sequence[index % sequence.count]
        let cycleOffset = CGFloat(index / sequence.count) * 0.07
        return (base + cycleOffset).truncatingRemainder(dividingBy: 1)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
