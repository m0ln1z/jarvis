// Settings window: edits config.json (Jarvis picks the changes up on the fly) and the Fish Audio key.
import AppKit
import Carbon
import SwiftUI

final class SettingsModel: ObservableObject {
    let dir: String
    var raw: [String: Any] = [:]  // the whole config, so unknown keys survive a save

    @Published var hotkey = "alt+j"
    @Published var wakeWords = ""
    @Published var awakeMinutes = 15.0
    @Published var brainModel = "haiku"
    @Published var asr = "mlx"
    @Published var listeningSound = true
    @Published var roots: [String] = []
    @Published var exclude = ""

    @Published var tts = "edge"
    @Published var voice = "ru-RU-DmitryNeural"
    @Published var rate = 0.0   // percent
    @Published var pitch = 0.0  // Hz
    @Published var fishVoice = ""
    @Published var fishKey = ""
    @Published var hasFishKey = false

    @Published var phrases: [String: String] = [:]
    @Published var aliases: [AliasRow] = []

    @Published var doubleClap = true
    @Published var clapLevel = 1.2
    @Published var status = ""

    struct AliasRow: Identifiable {
        let id = UUID()
        var project: String
        var names: String
    }

    static let phraseLabels: [(String, String)] = [
        ("wake", "После пароля"),
        ("listening", "Когда слушает (хлопок / горячая клавиша)"),
        ("opening", "Открывает проект ({name} — название)"),
        ("task", "Принял задачу"),
        ("stopped", "Остановил работу"),
        ("sleep", "Засыпает"),
        ("repeat", "Не расслышал"),
        ("not_found", "Проект не найден"),
        ("ready", "При запуске"),
    ]

    init(dir: String) {
        self.dir = dir
        load()
    }

    var configPath: String { dir + "/config.json" }
    var keyPath: String { dir + "/.fish_key" }

    func load() {
        guard let data = FileManager.default.contents(atPath: configPath),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        raw = cfg
        hotkey = cfg["hotkey"] as? String ?? "alt+j"
        wakeWords = (cfg["wake_words"] as? [String] ?? ["просыпайся", "папочка", "вернулся"]).joined(separator: " ")
        awakeMinutes = cfg["awake_minutes"] as? Double ?? 15
        brainModel = cfg["brain_model"] as? String ?? "haiku"
        asr = cfg["asr"] as? String ?? "mlx"
        listeningSound = cfg["listening_sound"] as? Bool ?? true
        roots = cfg["projects_roots"] as? [String] ?? ["~/Desktop"]
        exclude = (cfg["exclude"] as? [String] ?? []).joined(separator: ", ")
        tts = cfg["tts"] as? String ?? "edge"
        voice = cfg["voice"] as? String ?? "ru-RU-DmitryNeural"
        rate = Double((cfg["voice_rate"] as? String ?? "+0%").filter { "-0123456789".contains($0) }) ?? 0
        pitch = Double((cfg["voice_pitch"] as? String ?? "+0Hz").filter { "-0123456789".contains($0) }) ?? 0
        let fish = cfg["fish"] as? [String: Any] ?? [:]
        fishVoice = fish["reference_id"] as? String ?? ""
        hasFishKey = FileManager.default.fileExists(atPath: keyPath)
        phrases = cfg["phrases"] as? [String: String] ?? [:]
        aliases = (cfg["aliases"] as? [String: [String]] ?? [:]).sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { AliasRow(project: $0.key, names: $0.value.joined(separator: ", ")) }
        let clap = cfg["clap"] as? [String: Any] ?? [:]
        doubleClap = clap["double"] as? Bool ?? true
        clapLevel = clap["min_level"] as? Double ?? 1.2
    }

    func list(_ s: String, separator: Character) -> [String] {
        s.split(separator: separator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func save() {
        var cfg = raw
        cfg["hotkey"] = hotkey
        cfg["wake_words"] = list(wakeWords.lowercased(), separator: " ")
        cfg["awake_minutes"] = Int(awakeMinutes)
        cfg["brain_model"] = brainModel
        cfg["asr"] = asr
        cfg["listening_sound"] = listeningSound
        cfg["projects_roots"] = roots
        cfg["exclude"] = list(exclude, separator: ",")
        cfg["tts"] = tts
        cfg["voice"] = voice
        cfg["voice_rate"] = String(format: "%+d%%", Int(rate))
        cfg["voice_pitch"] = String(format: "%+dHz", Int(pitch))
        var fish = cfg["fish"] as? [String: Any] ?? ["model": "s2.1-pro-free"]
        fish["reference_id"] = fishVoice.trimmingCharacters(in: .whitespaces)
        cfg["fish"] = fish
        cfg["phrases"] = phrases
        var al: [String: [String]] = [:]
        for row in aliases where !row.project.isEmpty {
            al[row.project, default: []] += list(row.names, separator: ",")
        }
        cfg["aliases"] = al
        var clap = cfg["clap"] as? [String: Any] ?? [:]
        clap["double"] = doubleClap
        clap["min_level"] = (clapLevel * 100).rounded() / 100
        cfg["clap"] = clap

        let key = fishKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            FileManager.default.createFile(atPath: keyPath, contents: key.data(using: .utf8),
                                           attributes: [.posixPermissions: 0o600])
            fishKey = ""
            hasFishKey = true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? data.write(to: URL(fileURLWithPath: configPath))) != nil else {
            status = "Не удалось сохранить config.json"
            return
        }
        raw = cfg
        registerHotkey(hotkey)
        status = "Сохранено — Джарвис уже использует новые настройки"
    }

    /// Folders that look like projects in the chosen roots, for the alias picker.
    var projectNames: [String] {
        var names: [String] = []
        for root in roots {
            let path = (root as NSString).expandingTildeInPath
            let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for i in items.sorted(by: { $0.lowercased() < $1.lowercased() }) where !i.hasPrefix(".") {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path + "/" + i, isDirectory: &isDir), isDir.boolValue {
                    names.append(i)
                }
            }
        }
        return names
    }

    func preview() {
        save()
        let phrase = phrases["wake"].flatMap { $0.isEmpty ? nil : $0 } ?? "С возвращением, сэр."
        let p = Process()
        p.executableURL = URL(fileURLWithPath: dir + "/.venv/bin/python")
        p.arguments = [dir + "/jarvis.py", "--say", phrase]
        try? p.run()
    }

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"
        if panel.runModal() == .OK {
            let home = NSHomeDirectory()
            for url in panel.urls {
                let p = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
                if !roots.contains(p) { roots.append(p) }
            }
        }
    }
}

// ---------- hotkey recorder ----------

struct HotkeyField: View {
    @Binding var value: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(action: toggle) {
                Text(recording ? "Нажмите сочетание… (Esc — отмена)" : (parseHotkey(value)?.2 ?? value))
                    .frame(minWidth: 220)
                    .font(.system(.body, design: .rounded).weight(.semibold))
            }
            .controlSize(.large)
            Text("работает из любого приложения").foregroundColor(.secondary).font(.caption)
        }
    }

    func toggle() { recording ? stop() : start() }

    func start() {
        recording = true
        if let ref = hotkeyRef { UnregisterEventHotKey(ref); hotkeyRef = nil }  // so the current combo can be re-recorded
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            guard let key = keyCodes.first(where: { $0.value == Int(e.keyCode) })?.key else { return nil }
            var parts: [String] = []
            let f = e.modifierFlags
            if f.contains(.control) { parts.append("ctrl") }
            if f.contains(.option) { parts.append("alt") }
            if f.contains(.shift) { parts.append("shift") }
            if f.contains(.command) { parts.append("cmd") }
            if parts.isEmpty && !key.hasPrefix("f") { NSSound.beep(); return nil }  // a plain letter would break typing
            value = (parts + [key]).joined(separator: "+")
            stop()
            return nil
        }
    }

    func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        registerHotkey(value)
    }
}

// ---------- the window ----------

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    let voices = ["ru-RU-DmitryNeural", "ru-RU-SvetlanaNeural", "en-US-AndrewMultilingualNeural",
                  "en-US-BrianMultilingualNeural", "en-US-AvaMultilingualNeural", "en-US-EmmaMultilingualNeural",
                  "en-AU-WilliamMultilingualNeural", "de-DE-FlorianMultilingualNeural", "fr-FR-RemyMultilingualNeural"]

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                general.tabItem { Text("Основное") }
                voice.tabItem { Text("Голос") }
                phrases.tabItem { Text("Фразы") }
                aliases.tabItem { Text("Проекты") }
                claps.tabItem { Text("Хлопки") }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            Divider()
            HStack {
                Text(m.status).foregroundColor(.secondary).font(.callout)
                Spacer()
                Button("Открыть config.json") { NSWorkspace.shared.open(URL(fileURLWithPath: m.configPath)) }
                Button("Отменить изменения") { m.load(); m.status = "" }
                Button("Сохранить") { m.save() }.keyboardShortcut("s").buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 640, height: 560)
    }

    var general: some View {
        Form {
            Section("Горячая клавиша") {
                HotkeyField(value: $m.hotkey)
                Text("Первое нажатие — Джарвис слушает команду, повторное — отмена.").foregroundColor(.secondary).font(.caption)
            }
            Section("Пароль после хлопка") {
                TextField("Слова пароля", text: $m.wakeWords)
                Text("Достаточно произнести любые два слова из списка.").foregroundColor(.secondary).font(.caption)
                HStack {
                    Text("Не засыпать после пароля")
                    Slider(value: $m.awakeMinutes, in: 1...60, step: 1)
                    Text("\(Int(m.awakeMinutes)) мин").monospacedDigit().frame(width: 60, alignment: .trailing)
                }
            }
            Section("Распознавание речи") {
                Picker("Движок", selection: $m.asr) {
                    Text("MLX — быстро и точно (Apple Silicon)").tag("mlx")
                    Text("faster-whisper — процессор, для Intel").tag("faster-whisper")
                }
                Toggle("Короткий звук вместо «Да, сэр?» (быстрее)", isOn: $m.listeningSound)
            }
            Section("Мозг") {
                Picker("Модель", selection: $m.brainModel) {
                    Text("Haiku — быстрее").tag("haiku")
                    Text("Sonnet — умнее").tag("sonnet")
                    Text("Opus — самый умный, медленнее").tag("opus")
                }
            }
            Section("Где искать проекты") {
                ForEach(Array(m.roots.enumerated()), id: \.offset) { i, root in
                    HStack {
                        Text(root)
                        Spacer()
                        Button(role: .destructive) { m.roots.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Добавить папку…") { m.addRoot() }
                TextField("Не считать проектами (через запятую)", text: $m.exclude)
            }
        }
        .formStyle(.grouped)
    }

    var voice: some View {
        Form {
            Section("Сервис") {
                Picker("Голос через", selection: $m.tts) {
                    Text("Microsoft Edge — бесплатно").tag("edge")
                    Text("Fish Audio").tag("fish")
                }
                .pickerStyle(.segmented)
            }
            if m.tts == "edge" {
                Section("Голос Edge") {
                    Picker("Голос", selection: $m.voice) {
                        ForEach(voices + (voices.contains(m.voice) ? [] : [m.voice]), id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        Text("Скорость")
                        Slider(value: $m.rate, in: -30...30, step: 1)
                        Text("\(Int(m.rate))%").monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                    HStack {
                        Text("Тон")
                        Slider(value: $m.pitch, in: -30...30, step: 1)
                        Text("\(Int(m.pitch)) Hz").monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                }
            } else {
                Section("Fish Audio") {
                    TextField("ID голоса", text: $m.fishVoice)
                    Text("Из адреса страницы голоса: fish.audio/m/<ID>").foregroundColor(.secondary).font(.caption)
                    SecureField(m.hasFishKey ? "Ключ сохранён — введите новый, чтобы заменить" : "API-ключ", text: $m.fishKey)
                    Text("Ключ хранится в файле .fish_key, доступном только вам.").foregroundColor(.secondary).font(.caption)
                }
            }
            Section {
                Button("Сохранить и прослушать") { m.preview() }
            }
        }
        .formStyle(.grouped)
    }

    var phrases: some View {
        Form {
            Section("Что говорит Джарвис") {
                ForEach(SettingsModel.phraseLabels, id: \.0) { key, label in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label).font(.caption).foregroundColor(.secondary)
                        TextField(label, text: Binding(get: { m.phrases[key] ?? "" }, set: { m.phrases[key] = $0 }))
                            .labelsHidden()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    var aliases: some View {
        let names = m.projectNames
        return Form {
            Section {
                ForEach($m.aliases) { $row in
                    HStack {
                        Picker("", selection: $row.project) {
                            Text("— проект —").tag("")
                            ForEach(names + (names.contains(row.project) || row.project.isEmpty ? [] : [row.project]), id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        TextField("как называть голосом, через запятую", text: $row.names)
                        Button(role: .destructive) { m.aliases.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Добавить прозвище") { m.aliases.append(.init(project: "", names: "")) }
            } header: {
                Text("Голосовые прозвища проектов")
            } footer: {
                Text("Проекты и так находятся по звучанию названия. Прозвище нужно, если название трудно выговорить или Джарвис путает похожие проекты.")
                    .foregroundColor(.secondary).font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    var claps: some View {
        Form {
            Section("Хлопки") {
                Toggle("Двойной хлопок (рекомендуется — меньше ложных срабатываний)", isOn: $m.doubleClap)
                HStack {
                    Text("Порог громкости")
                    Slider(value: $m.clapLevel, in: 0.3...6, step: 0.1)
                    Text(String(format: "%.1f", m.clapLevel)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Text("Меньше — чувствительнее. Если срабатывает на речь или стук — увеличьте. Узнать уровни своих хлопков: `jarvis --levels` в Терминале.")
                    .foregroundColor(.secondary).font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

final class SettingsWindow {
    static var window: NSWindow?

    static func show(dir: String) {
        if window == nil {
            let model = SettingsModel(dir: dir)
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(m: model)))
            w.title = "Джарвис — настройки"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)  // the app is a menu bar accessory: bring the window to the front
        window?.makeKeyAndOrderFront(nil)
    }
}
