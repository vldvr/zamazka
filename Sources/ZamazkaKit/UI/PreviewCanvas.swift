import AppKit
import SwiftUI

/// The screenshot with findings marked on it. Click a mark to keep that spot visible, drag on an
/// empty place to hide one more. After «Скрыть» it shows the cleaned picture, which can be
/// dragged straight into a chat.
struct PreviewCanvas: View {
    @ObservedObject var session: Session
    let size: CGSize
    /// Ink sweeps over the marks; set just before the cleaned picture replaces the preview.
    var inking = false
    var interactive = true

    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var k: CGFloat { size.width / max(1, session.size.width) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            picture
            if session.state != .applied {
                marks
                draft
                if interactive { input }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var picture: some View {
        if session.state == .applied, let cleaned = session.cleaned {
            Image(decorative: cleaned, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .onDrag { dragProvider() } preview: {
                    Image(decorative: cleaned, scale: 1).resizable().scaledToFit().frame(width: 180)
                }
                .help("Перетащите в чат")
        } else if let original = session.original {
            Image(decorative: original, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
        } else {
            Rectangle().fill(.quaternary)
        }
    }

    private var marks: some View {
        ForEach(Array(session.findings.enumerated()), id: \.element.id) { index, finding in
            ForEach(Array(finding.rects.enumerated()), id: \.offset) { _, rect in
                mark(for: finding, rect: viewRect(rect), index: index)
            }
        }
    }

    @ViewBuilder
    private func mark(for finding: Finding, rect r: CGRect, index: Int) -> some View {
        let radius = min(4, r.height * 0.2)
        ZStack(alignment: .leading) {
            if finding.enabled {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.markerFill)
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.markerEdge, lineWidth: 1.25)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.ink)
                    .frame(width: inking ? r.width : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2).delay(Double(index) * 0.03), value: inking)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
            }
        }
        .frame(width: max(r.width, 2), height: max(r.height, 2))
        .offset(x: r.minX, y: r.minY)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var draft: some View {
        if let a = dragStart, let b = dragNow {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.markerFill)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.markerEdge, style: StrokeStyle(lineWidth: 1.25, dash: [4, 3])))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
        }
    }

    private var input: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragStart == nil { dragStart = v.startLocation }
                        if hypot(v.translation.width, v.translation.height) > 3 { dragNow = clamp(v.location) }
                    }
                    .onEnded { v in
                        defer { dragStart = nil; dragNow = nil }
                        if hypot(v.translation.width, v.translation.height) <= 3 {
                            if let hit = hitFinding(at: v.startLocation) { session.toggle(hit) }
                        } else if let a = dragStart {
                            let b = clamp(v.location)
                            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                            session.addManual(imageRect(r))
                        }
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): (hitFinding(at: p) != nil ? NSCursor.pointingHand : NSCursor.crosshair).set()
                case .ended: NSCursor.arrow.set()
                }
            }
    }

    // MARK: - Geometry

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k)
    }

    private func imageRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX / k, y: r.minY / k, width: r.width / k, height: r.height / k)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), size.width), y: min(max(0, p.y), size.height))
    }

    /// The smallest mark under the point, so a mark inside a bigger one stays reachable.
    private func hitFinding(at p: CGPoint) -> UUID? {
        session.findings
            .filter { f in f.rects.contains { viewRect($0).insetBy(dx: -3, dy: -3).contains(p) } }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }?
            .id
    }

    private func dragProvider() -> NSItemProvider {
        if let url = session.dragFile, let provider = NSItemProvider(contentsOf: url) {
            provider.suggestedName = url.deletingPathExtension().lastPathComponent
            return provider
        }
        return NSItemProvider()
    }

    private var accessibilityText: String {
        if session.state == .applied { return "Снимок, личные данные закрыты. Можно перетащить в чат." }
        let kinds = session.findings.filter(\.enabled).kinds.map(\.inline).joined(separator: ", ")
        return kinds.isEmpty ? "Снимок, ничего не отмечено" : "Снимок, отмечено: \(kinds)"
    }
}
