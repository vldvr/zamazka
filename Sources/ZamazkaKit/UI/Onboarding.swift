import AppKit
import SwiftUI

/// First run: what the app does, the two permissions it needs, and two settings worth changing.
struct OnboardingView: View {
    @StateObject private var status = SourcesStatus()
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Замазка").font(.system(size: 20, weight: .semibold))
                    Text("Проверяет новые скриншоты и закрывает на них личные данные: телефон, карту, паспорт, адрес, ключи. Всё считается на этом Mac, в сеть ничего не уходит.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 18)

            VStack(spacing: 0) {
                step(done: status.folderReadable,
                     title: "Папка со снимками: \(status.folderName)",
                     text: "macOS один раз спросит, можно ли Замазке читать эту папку.",
                     button: "Разрешить") {
                    _ = try? FileManager.default.contentsOfDirectory(atPath: status.systemFolder.path)
                    status.refresh()
                }
                Divider()
                step(done: status.clipboardAccess == "есть",
                     title: "Буфер обмена",
                     text: "Для снимков в буфер (⌃⌘⇧4) и кнопки Copy в CleanShot. Если macOS спросит про вставку из других приложений, разрешите.",
                     button: "Разрешить") {
                    CaptureCenter.shared.clipboard.requestAccess()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { status.refresh() }
                }
                Divider()
                step(done: !status.thumbnail,
                     title: "Миниатюра после снимка",
                     text: "Лучше выключить: пока она в углу экрана, файла ещё нет, а картинка, перетащенная из неё, уходит без проверки.",
                     button: "Выключить") {
                    ScreenshotPlaces.setThumbnail(false)
                    status.refresh()
                }
                if status.synced {
                    Divider()
                    step(done: false,
                         title: "Папка синхронизируется с облаком",
                         text: "Оригинал может уйти в облако раньше, чем Замазка его заменит. Надёжнее сохранять снимки в папку на этом Mac.",
                         button: "Перенести") {
                        let url = ScreenshotPlaces.suggestedLocalFolder
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        ScreenshotPlaces.setSystemFolder(url)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            status.refresh()
                            CaptureCenter.shared.refreshSources()
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

            HStack {
                Button("Показать на примере") { CaptureCenter.shared.showDemo() }
                    .buttonStyle(CardButtonStyle(prominent: false))
                Spacer()
                Button("Готово") { close() }
                    .buttonStyle(CardButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { status.refresh() }
    }

    private func step(done: Bool, title: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(done ? Color.green : Color.secondary)
                .padding(.top, 1)
                .accessibilityLabel(done ? "Готово" : "Не сделано")
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !done {
                Button(button, action: action).controlSize(.small)
            }
        }
        .padding(.vertical, 12)
    }
}

@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView { [weak self] in
                Prefs.shared.onboardingDone = true
                self?.window?.close()
            }))
            w.title = "Замазка"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
