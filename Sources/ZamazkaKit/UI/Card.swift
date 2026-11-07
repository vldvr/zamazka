import AppKit
import Combine
import SwiftUI

// MARK: - View

/// The small card that appears under the menu bar icon when a screenshot has personal data.
struct CardView: View {
    @ObservedObject var session: Session
    @ObservedObject var controller: CardController
    var solid = false

    @State private var inking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var center: CaptureCenter { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            PreviewCanvas(session: session, size: controller.previewSize(for: session), inking: inking,
                          interactive: session.state == .review && !inking)
                .padding(.horizontal, 12)
            details
                .padding(.horizontal, 12)
                .padding(.top, 10)
            buttons
                .padding(12)
        }
        .frame(width: controller.cardWidth(for: session))
        .cardSurface(solid: solid)
        .onHover { controller.hovering = $0 }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if session.state == .review || session.state == .applied {
                IconButton(symbol: controller.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           help: controller.expanded ? "Уменьшить" : "Крупнее") { controller.toggleExpanded() }
            }
            IconButton(symbol: "xmark", help: "Закрыть") { controller.dismiss() }
        }
    }

    private var title: String {
        switch session.state {
        case .analyzing: return "Проверяю снимок"
        case .review:
            return session.findings.hasStrong || session.findings.contains { $0.kind == .manual }
                ? "Личные данные на снимке" : "Ничего не нашлось"
        case .applied: return "Скрыто \(places(session.findings.filter(\.enabled).count))"
        case .clean: return "Ничего не нашлось"
        case .failed: return "Не удалось проверить снимок"
        }
    }

    private var subtitle: String {
        if session.isDemo { return "Пример на выдуманных данных" }
        let p = session.placesText
        return p.isEmpty ? session.origin.title : "\(session.origin.title), \(p)"
    }

    // MARK: Details

    @ViewBuilder private var details: some View {
        switch session.state {
        case .review:
            VStack(alignment: .leading, spacing: 8) {
                if !session.findings.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(session.findings.kinds) { kind in chip(kind) }
                    }
                }
                Text("Нажмите на отметку, чтобы оставить это место видимым. Протяните мышью, чтобы скрыть ещё.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .applied:
            VStack(alignment: .leading, spacing: 4) {
                Text(appliedText)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                if let note = session.note {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.canUndo, Prefs.shared.keepOriginalMinutes > 0 {
                    Text("Оригинал в памяти \(minutesText(Prefs.shared.keepOriginalMinutes)), на диск не пишется.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .analyzing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Первый снимок после запуска проверяется дольше.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .clean:
            Text("На снимке нет того, что Замазка умеет искать. Можно отметить место вручную.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var appliedText: String {
        if session.isDemo { return "Это пример: файлы и буфер обмена не менялись. Картинку можно перетащить." }
        if session.targets.contains(.clipboard), session.note == nil {
            return "В буфере обмена очищенная копия: вставьте её в чат или перетащите картинку."
        }
        return "Файл заменён очищенной копией. Картинку можно перетащить в чат."
    }

    private func chip(_ kind: FindingKind) -> some View {
        let items = session.findings.filter { $0.kind == kind }
        let on = items.filter(\.enabled).count
        let state: ChipState = on == items.count ? .on : (on == 0 ? .off : .mixed)
        return Button { session.toggleKind(kind) } label: {
            HStack(spacing: 5) {
                Image(systemName: state.symbol).font(.system(size: 10, weight: .bold))
                Text(kind.title)
                if items.count > 1 { Text("\(items.count)").monospacedDigit().opacity(0.7) }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .foregroundStyle(state == .off ? Color.secondary : Theme.onMarker)
            .background(Capsule().fill(state == .off ? Color.clear : Theme.marker.opacity(state == .on ? 1 : 0.5)))
            .overlay(Capsule().strokeBorder(state == .off ? Color.secondary.opacity(0.6) : Color.clear,
                                            style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(state == .off ? "Скрывать: \(kind.inline)" : "Оставить видимым: \(kind.inline)")
        .accessibilityLabel(kind.title)
        .accessibilityValue(state == .off ? "останется видимым" : "будет скрыто")
    }

    enum ChipState {
        case on, off, mixed
        var symbol: String {
            switch self {
            case .on: return "checkmark"
            case .off: return "eye"
            case .mixed: return "minus"
            }
        }
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            switch session.state {
            case .review, .clean:
                Button("Оставить как есть") { controller.dismiss() }
                    .buttonStyle(CardButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Скрыть") { hide() }
                    .buttonStyle(CardButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.findings.enabledCount == 0 || inking)
            case .applied:
                if session.canUndo {
                    Button("Вернуть") { center.undo(session) }
                        .buttonStyle(CardButtonStyle(prominent: false))
                        .keyboardShortcut("z", modifiers: .command)
                }
                Spacer()
                Button("Готово") { controller.dismiss() }
                    .buttonStyle(CardButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Закрыть") { controller.dismiss() }
                    .buttonStyle(CardButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Проверить ещё раз") { center.retry(session) }
                    .buttonStyle(CardButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            case .analyzing:
                Spacer()
                Button("Закрыть") { controller.dismiss() }
                    .buttonStyle(CardButtonStyle(prominent: false))
            }
        }
    }

    /// One short sweep of ink over the marks, then the real cleaned picture.
    private func hide() {
        if reduceMotion || solid {
            center.apply(session)
            return
        }
        inking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            center.apply(session)
            inking = false
        }
    }

    private func minutesText(_ m: Int) -> String {
        if m >= 60 { return m == 60 ? "ещё час" : "ещё \(m / 60) ч" }
        let m10 = m % 10, m100 = m % 100
        let word = (m10 == 1 && m100 != 11) ? "минуту" : ((2...4).contains(m10) && !(12...14).contains(m100) ? "минуты" : "минут")
        return "ещё \(m) \(word)"
    }
}

// MARK: - Window

final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the card window: where it sits, how big it is, when it goes away.
@MainActor
final class CardController: ObservableObject {
    static let shared = CardController()

    @Published var expanded = false { didSet { relayout(animated: true) } }
    @Published var hovering = false { didSet { if !hovering { armAutoClose() } else { closeTimer?.invalidate() } } }
    private(set) var session: Session?
    private var panel: CardPanel?
    private var hosting: NSHostingView<CardView>?
    private var watch: AnyCancellable?
    private var closeTimer: Timer?

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ session: Session) {
        let isNew = self.session !== session || panel?.isVisible != true
        self.session = session
        if isNew { expanded = false }
        let view = CardView(session: session, controller: self)
        if let hosting {
            hosting.rootView = view
        } else {
            let h = NSHostingView(rootView: view)
            hosting = h
            let p = CardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = false
            p.isMovableByWindowBackground = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.contentView = h
            p.title = "Замазка"
            panel = p
        }
        watch = session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.relayout(animated: false)
                    self?.armAutoClose()
                }
            }
        relayout(animated: false)
        if isNew { appear() }
        armAutoClose()
    }

    func dismiss() {
        closeTimer?.invalidate()
        guard let panel, panel.isVisible else { return }
        NSCursor.arrow.set()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    func toggleExpanded() { expanded.toggle() }

    // MARK: Layout

    private var screen: NSScreen {
        StatusItemController.shared.buttonScreen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func previewSize(for session: Session) -> CGSize {
        let aspect = max(0.2, session.size.width / max(1, session.size.height))
        let maxW: CGFloat, maxH: CGFloat
        if expanded {
            let f = screen.visibleFrame
            maxW = min(f.width * 0.72, session.size.width / 2 * 1.2)
            maxH = f.height * 0.72
        } else {
            maxW = 340
            maxH = 230
        }
        var w = min(maxW, maxH * aspect)
        w = max(w, min(maxW, 220))
        return CGSize(width: w.rounded(), height: (w / aspect).rounded())
    }

    func cardWidth(for session: Session) -> CGFloat {
        max(previewSize(for: session).width + 24, 340)
    }

    private func relayout(animated: Bool) {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        let f = screen.visibleFrame
        var origin: CGPoint
        if expanded {
            origin = CGPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)
        } else {
            // Under the menu bar icon, right edge aligned with it. Far from the system thumbnail
            // (bottom right) and from CleanShot's overlay (bottom left or bottom right).
            let anchor = StatusItemController.shared.buttonFrame
            let right = min((anchor?.maxX ?? f.maxX - 10) + 8, f.maxX - 8)
            origin = CGPoint(x: right - size.width, y: f.maxY - 6 - size.height)
        }
        origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
        origin.y = max(origin.y, f.minY + 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func appear() {
        guard let panel else { return }
        let final = panel.frame
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.setFrame(final.offsetBy(dx: 0, dy: 8), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
    }

    /// After «Скрыть» the card leaves on its own unless the pointer is on it. Before that it
    /// waits: the decision is the person's.
    private func armAutoClose() {
        closeTimer?.invalidate()
        guard let session, session.state == .applied, !hovering, !expanded else { return }
        let t = Timer(timeInterval: 14, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session === session, session.state == .applied, !self.hovering else { return }
                self.dismiss()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        closeTimer = t
    }
}
