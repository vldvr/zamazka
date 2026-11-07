import AppKit
import SwiftUI

/// What the settings and the first-run window show about screenshot sources. Read on demand:
/// none of it has a change notification.
@MainActor
final class SourcesStatus: ObservableObject {
    @Published var systemFolder = ScreenshotPlaces.systemFolder
    @Published var toClipboard = ScreenshotPlaces.systemTargetIsClipboard
    @Published var thumbnail = ScreenshotPlaces.showsThumbnail
    @Published var synced = ScreenshotPlaces.isSynced(ScreenshotPlaces.systemFolder)
    @Published var cleanShot = ScreenshotPlaces.cleanShotInstalled
    @Published var folderReadable = false
    @Published var clipboardAccess = ""

    func refresh() {
        systemFolder = ScreenshotPlaces.systemFolder
        toClipboard = ScreenshotPlaces.systemTargetIsClipboard
        thumbnail = ScreenshotPlaces.showsThumbnail
        synced = ScreenshotPlaces.isSynced(systemFolder)
        cleanShot = ScreenshotPlaces.cleanShotInstalled
        folderReadable = (try? FileManager.default.contentsOfDirectory(atPath: systemFolder.path)) != nil
        let cb = CaptureCenter.shared.clipboard
        if cb.accessDenied { clipboardAccess = "запрещён в настройках macOS" }
        else if cb.accessAsksEveryTime { clipboardAccess = "macOS спрашивает каждый раз" }
        else { clipboardAccess = "есть" }
    }

    var folderName: String {
        systemFolder.standardizedFileURL == ScreenshotPlaces.desktop.standardizedFileURL
            ? "Рабочий стол" : FileManager.default.displayName(atPath: systemFolder.path)
    }

    static func openPastePrivacy() {
        let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard",
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    @StateObject private var status = SourcesStatus()

    var body: some View {
        TabView {
            general.tabItem { Label("Основное", systemImage: "gearshape") }
            kinds.tabItem { Label("Что искать", systemImage: "text.magnifyingglass") }
            sources.tabItem { Label("Источники", systemImage: "camera.viewfinder") }
        }
        .frame(width: 560, height: 560)
        .onAppear { status.refresh() }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section("После снимка") {
                Picker("", selection: $prefs.afterCapture) {
                    Text("Показывать карточку и ждать «Скрыть»").tag(AfterCapture.ask)
                    Text("Скрывать сразу, в карточке останется «Вернуть»").tag(AfterCapture.auto)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Если на снимке ничего не нашлось, Замазка ничего не показывает.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Чем закрывать", selection: $prefs.fill) {
                    ForEach(FillStyle.allCases) { Text($0.title).tag($0) }
                }
                if prefs.fill == .solid {
                    Picker("Цвет", selection: $prefs.fillColor) {
                        ForEach(FillColor.allCases) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("Как скрывать")
            } footer: {
                Text("Размытия и пикселизации здесь нет намеренно: по ним текст восстанавливают, для этого есть готовые инструменты вроде Depix и Unredacter. Заливка одного цвета и шум не содержат ни одного пикселя из закрытого места, «Под цвет фона» берёт цвет только снаружи.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Хранить для «Вернуть»", selection: $prefs.keepOriginalMinutes) {
                    Text("Не хранить").tag(0)
                    Text("1 минуту").tag(1)
                    Text("10 минут").tag(10)
                    Text("1 час").tag(60)
                }
            } header: {
                Text("Оригинал")
            } footer: {
                Text("Оригинал после «Скрыть» лежит только в памяти, на диск Замазка его не пишет. Когда время выйдет или программа закроется, вернуть его будет нельзя. Пока не нажато «Скрыть», оригинал остаётся там, где его сохранил macOS или CleanShot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Запуск") {
                Toggle("Открывать при входе в систему", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Kinds

    private static let groups: [(String, [FindingKind])] = [
        ("Связь", [.phone, .email]),
        ("Деньги", [.card, .account]),
        ("Документы", [.passport, .snils, .inn, .oms]),
        ("О человеке", [.person, .birthdate, .address, .plate]),
        ("Покупки", [.order, .track]),
        ("Техника", [.secret, .password, .ip]),
        ("На картинке", [.code, .face]),
    ]

    private var kinds: some View {
        Form {
            ForEach(Self.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { kind in
                        Toggle(isOn: Binding(get: { prefs.isEnabled(kind) }, set: { prefs.setEnabled(kind, $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.title)
                                Text(kind.example).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                TextEditor(text: Binding(
                    get: { prefs.customWords.joined(separator: "\n") },
                    set: { prefs.customWords = $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ))
                .font(.system(size: 12))
                .frame(height: 70)
            } header: {
                Text("Свои слова")
            } footer: {
                Text("По одному на строку: фамилия, название улицы, логин. Регистр не важен. Хранятся в настройках этого Mac открытым текстом.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Sources

    private var sources: some View {
        Form {
            Section("Системные снимки") {
                Toggle("Проверять новые файлы снимков", isOn: $prefs.watchFiles)
                LabeledContent("Папка") {
                    HStack {
                        Text(status.folderName)
                        Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([status.systemFolder]) }
                    }
                }
                if status.toClipboard {
                    Text("В ⌘⇧5 выбрано сохранение в буфер обмена: снимки придут через буфер.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if status.synced {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Эта папка синхронизируется с облаком. Оригинал может уйти туда раньше, чем Замазка его заменит.", systemImage: "icloud")
                            .font(.callout)
                        Button("Сохранять снимки в «Изображения/Снимки экрана»") {
                            let url = ScreenshotPlaces.suggestedLocalFolder
                            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            ScreenshotPlaces.setSystemFolder(url)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { status.refresh(); CaptureCenter.shared.refreshSources() }
                        }
                    }
                }
                LabeledContent("Миниатюра после снимка") {
                    if status.thumbnail {
                        Button("Выключить") { ScreenshotPlaces.setThumbnail(false); status.refresh() }
                    } else {
                        Text("выключена").foregroundStyle(.secondary)
                    }
                }
                Text("Пока миниатюра в углу экрана, macOS не сохраняет файл, а перетащенная из неё картинка уходит без проверки. Без миниатюры файл появляется сразу.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Буфер обмена") {
                Toggle("Проверять картинки в буфере", isOn: $prefs.watchClipboard)
                Picker("Какие", selection: $prefs.clipboardScope) {
                    Text("Только снимки экрана").tag(ClipboardScope.screenshots)
                    Text("Любые картинки").tag(ClipboardScope.anyImage)
                }
                LabeledContent("Доступ") {
                    HStack {
                        Text(status.clipboardAccess)
                        if status.clipboardAccess != "есть" {
                            Button("Открыть настройки") { SourcesStatus.openPastePrivacy() }
                        }
                    }
                }
                Text("Замазка смотрит на счётчик изменений буфера и читает содержимое, только когда там картинка. Менеджеры буфера обмена успевают сохранить оригинал раньше: в них снимки лучше исключить.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("CleanShot X") {
                LabeledContent("Установлен") { Text(status.cleanShot ? "да" : "нет").foregroundStyle(.secondary) }
                Toggle("Заменять и копию в истории CleanShot", isOn: $prefs.replaceCleanShotHistory)
                Text("CleanShot хранит каждый снимок у себя для окошка быстрого доступа. Если копию не заменить, кнопки Copy и Drag в этом окошке отдадут оригинал.")
                    .font(.caption).foregroundStyle(.secondary)
                if !prefs.learnedFolders.isEmpty {
                    LabeledContent("Найденные папки") {
                        VStack(alignment: .trailing) {
                            ForEach(prefs.learnedFolders, id: \.self) { Text(($0 as NSString).abbreviatingWithTildeInPath).font(.caption) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { status.refresh() }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Настройки Замазки"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
