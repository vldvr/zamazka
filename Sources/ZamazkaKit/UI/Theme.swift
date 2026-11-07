import AppKit
import SwiftUI

/// Two materials carry the whole look: a yellow marker for "found" and ink for "hidden".
/// Everything else is the system's own colours and type.
enum Theme {
    static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
    }

    /// Highlighter yellow for findings that will be hidden.
    static let marker = Color(nsColor: NSColor(hex: 0xFFC21A))
    static let markerFill = Color(nsColor: NSColor(hex: 0xFFC21A, alpha: 0.38))
    static let markerEdge = dynamic(light: 0xC98A00, dark: 0xFFC21A)
    /// Text on marker yellow.
    static let onMarker = Color(nsColor: NSColor(hex: 0x16181B))

    /// The fill colour of hidden areas, same as in the saved picture.
    static let ink = Color(nsColor: NSColor(hex: 0x16181B))

    /// Primary button: ink on light, chalk on dark.
    static let primary = dynamic(light: 0x16181B, dark: 0xF1F1EE)
    static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x16181B)

    static let hairline = Color(nsColor: .separatorColor)
}

extension View {
    /// Card surface: the popover material, a hairline edge and a soft shadow from the window.
    func cardSurface(radius: CGFloat = 14, solid: Bool = false) -> some View {
        background {
            if solid {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
            } else {
                VisualEffect(material: .popover).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Primary and secondary buttons of the card. Plain shapes so they look the same in every
/// macOS version and in rendered README pictures.
struct CardButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .foregroundStyle(prominent ? Theme.onPrimary : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Theme.primary : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08))
            )
            .opacity(enabled ? (configuration.isPressed && prominent ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Rectangle())
    }
}

/// Small borderless icon button for the card header.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Lays chips out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
