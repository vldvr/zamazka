import AppKit
import Combine
import UniformTypeIdentifiers

/// The menu bar icon and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private var item: NSStatusItem?
    private var bag: Set<AnyCancellable> = []
    private var blink: Timer?

    var buttonFrame: CGRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        let f = window.convertToScreen(button.convert(button.bounds, to: nil))
        return f.width > 0 ? f : nil
    }

    var buttonScreen: NSScreen? { item?.button?.window?.screen }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        item.button?.toolTip = "Замазка"
        item.button?.setAccessibilityLabel("Замазка")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()

        CaptureCenter.shared.$busy
            .sink { [weak self] busy in self?.setBusy(busy) }
            .store(in: &bag)
        Prefs.shared.$pausedUntil
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &bag)
    }

    private func updateIcon(dim: Bool = false) {
        let paused = Prefs.shared.isPaused
        let image = NSImage(systemSymbolName: paused ? "text.redaction" : "text.redaction",
                            accessibilityDescription: "Замазка")
        image?.isTemplate = true
        item?.button?.image = image
        item?.button?.appearsDisabled = paused || dim
    }

    /// While a picture is being checked the icon pulses, so a slow first check is not mistaken
    /// for silence.
    private func setBusy(_ busy: Bool) {
        blink?.invalidate()
        blink = nil
        guard busy else { updateIcon(); return }
        var dim = false
        let t = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                dim.toggle()
                self?.updateIcon(dim: dim)
            }
        }
        // Only after a short while: quick checks should not flicker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard CaptureCenter.shared.busy, self?.blink == nil else { return }
            RunLoop.main.add(t, forMode: .common)
            self?.blink = t
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Prefs.shared
        let center = CaptureCenter.shared

        let status: String
        if prefs.isPaused, let until = prefs.pausedUntil {
            status = "На паузе до \(time(until))"
        } else if center.busy {
            status = "Проверяю снимок…"
        } else {
            status = "Проверяю новые снимки"
        }
        menu.addItem(disabled(status))

        let recent = center.sessions.filter { !$0.isDemo }
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabled("Последние"))
            for s in recent.prefix(6) {
                let item = NSMenuItem(title: describe(s), action: #selector(openSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s.id
                item.isEnabled = s.state != .clean && (s.original != nil || s.cleaned != nil)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(action("Проверить картинку…", #selector(pickFile)))
        menu.addItem(action("Проверить буфер обмена", #selector(checkClipboard)))
        menu.addItem(.separator())
        if prefs.isPaused {
            menu.addItem(action("Снять с паузы", #selector(resume)))
        } else {
            menu.addItem(action("Пауза на час", #selector(pause)))
        }
        menu.addItem(.separator())
        menu.addItem(action("Настройки…", #selector(openSettings), key: ","))
        menu.addItem(action("Выйти", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func describe(_ s: Session) -> String {
        let kinds = s.findings.filter { !$0.weak || $0.enabled }.kinds.prefix(3).map(\.inline).joined(separator: ", ")
        let what: String
        switch s.state {
        case .analyzing: what = "проверяется"
        case .review: what = kinds.isEmpty ? "не скрыто" : "\(kinds), не скрыто"
        case .applied: what = "\(kinds), скрыто"
        case .clean: what = "ничего не нашлось"
        case .failed: what = "не проверен"
        }
        return "\(time(s.created))   \(what)"
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let s = CaptureCenter.shared.sessions.first(where: { $0.id == id }) else { return }
        CardController.shared.show(s)
    }

    @objc private func pickFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.prompt = "Проверить"
        panel.message = "Найденное будет закрыто в этом же файле, если нажать «Скрыть»."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        CaptureCenter.shared.checkFile(url)
    }

    @objc private func checkClipboard() { CaptureCenter.shared.checkClipboard() }
    @objc private func pause() { Prefs.shared.pausedUntil = Date().addingTimeInterval(3600) }
    @objc private func resume() { Prefs.shared.pausedUntil = nil }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
