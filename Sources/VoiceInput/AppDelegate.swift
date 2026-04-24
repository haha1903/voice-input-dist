import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let keyMonitor = KeyMonitor()
    private let speechEngine = SpeechEngine()
    private let textInjector = TextInjector()
    private lazy var overlayPanel = OverlayPanel()

    private var isEnabled = true
    private var isRecording = false
    private var isTranscribing = false

    private var enableMenuItem: NSMenuItem!
    private var modelStatusItem: NSMenuItem!
    private var languageItems: [NSMenuItem] = []
    private var modelItems: [NSMenuItem] = []
    private var hotkeyItems: [NSMenuItem] = []
    private var isModelReady = false

    private var selectedLanguage: String {
        get { UserDefaults.standard.string(forKey: "whisperLanguage") ?? "zh" }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : newValue, forKey: "whisperLanguage") }
    }

    private var selectedModel: String {
        get { UserDefaults.standard.string(forKey: "whisperModel") ?? "large-v3_turbo" }
        set { UserDefaults.standard.set(newValue, forKey: "whisperModel") }
    }

    private var selectedHotkey: HotkeyType {
        get {
            let raw = UserDefaults.standard.string(forKey: "hotkey") ?? HotkeyType.rightCommand.rawValue
            return HotkeyType(rawValue: raw) ?? .rightCommand
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkey") }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        speechEngine.languageCode = selectedLanguage.isEmpty ? nil : selectedLanguage
        keyMonitor.hotkey = selectedHotkey

        setupStatusBar()
        setupSpeechCallbacks()

        if !keyMonitor.start() {
            showAccessibilityAlert()
        }

        keyMonitor.onHotkeyToggle = { [weak self] in self?.hotkeyToggle() }
    }

    // MARK: - Key events

    private func hotkeyToggle() {
        guard isEnabled else { return }
        if isRecording {
            stopAndTranscribe()
        } else if !isTranscribing {
            guard isModelReady else {
                overlayPanel.show(text: modelStatusItem?.title ?? "Model not ready")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                    self?.overlayPanel.dismiss()
                }
                NSSound(named: .init("Funk"))?.play()
                return
            }
            startListening()
        }
    }

    private func startListening() {
        isRecording = true
        updateStatusIcon(recording: true)
        overlayPanel.show(text: "Listening...")
        NSSound(named: .init("Tink"))?.play()
        speechEngine.startRecording()
    }

    private func stopAndTranscribe() {
        isRecording = false
        isTranscribing = true
        updateStatusIcon(recording: false)
        overlayPanel.updateText("Transcribing...")
        speechEngine.stopRecording()
    }

    // MARK: - Speech callbacks

    private func setupSpeechCallbacks() {
        speechEngine.onFinalResult = { [weak self] text in
            guard let self else { return }
            self.isTranscribing = false
            self.finishTranscription(text: text)
        }

        speechEngine.onError = { [weak self] msg in
            guard let self else { return }
            self.isTranscribing = false
            self.overlayPanel.updateText("Error: \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                self.overlayPanel.dismiss()
            }
        }

        speechEngine.onAudioLevel = { [weak self] level in
            self?.overlayPanel.updateAudioLevel(level)
        }

        speechEngine.onModelLoading = { [weak self] msg in
            guard let self else { return }
            self.isModelReady = false
            self.statusItem.button?.toolTip = msg
            self.modelStatusItem?.title = msg
        }

        speechEngine.onModelReady = { [weak self] in
            guard let self else { return }
            self.isModelReady = true
            self.statusItem.button?.toolTip = "VoiceInput (ready)"
            self.modelStatusItem?.title = "Model: ready"
        }
    }

    private func finishTranscription(text rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            overlayPanel.dismiss()
            return
        }

        overlayPanel.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.textInjector.inject(text)
            NSSound(named: .init("Pop"))?.play()
        }
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(recording: false)

        let menu = NSMenu()

        modelStatusItem = NSMenuItem(title: "Model: initializing...", action: nil, keyEquivalent: "")
        modelStatusItem.isEnabled = false
        menu.addItem(modelStatusItem)

        menu.addItem(.separator())

        enableMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enableMenuItem.target = self
        enableMenuItem.state = .on
        menu.addItem(enableMenuItem)

        menu.addItem(.separator())

        // Hotkey submenu
        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu()
        for type in HotkeyType.allCases {
            let item = NSMenuItem(title: type.displayName, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = type.rawValue
            item.state = type == selectedHotkey ? .on : .off
            hotkeyItems.append(item)
            hotkeyMenu.addItem(item)
        }
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        // Language submenu
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        let languages: [(String, String)] = [
            ("Auto Detect (mixed)", ""),
            ("English", "en"),
            ("中文", "zh"),
            ("日本語", "ja"),
            ("한국어", "ko"),
        ]
        for (name, code) in languages {
            let item = NSMenuItem(title: name, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = code == selectedLanguage ? .on : .off
            languageItems.append(item)
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // Model submenu
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        let models = [
            "tiny",
            "base",
            "small",
            "medium",
            "large-v3",
            "large-v3_turbo",
        ]
        for name in models {
            let item = NSMenuItem(title: name, action: #selector(changeModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == selectedModel ? .on : .off
            modelItems.append(item)
            modelMenu.addItem(item)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit VoiceInput", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        let name = recording ? "mic.fill" : "mic"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Voice Input")
        button.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        enableMenuItem.state = isEnabled ? .on : .off

        if isEnabled {
            if !keyMonitor.start() {
                showAccessibilityAlert()
            }
        } else {
            keyMonitor.stop()
            if isRecording {
                speechEngine.cancel()
                overlayPanel.dismiss()
                isRecording = false
                updateStatusIcon(recording: false)
            }
        }
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let type = HotkeyType(rawValue: raw) else { return }
        selectedHotkey = type
        keyMonitor.hotkey = type

        for item in hotkeyItems {
            item.state = (item.representedObject as? String) == raw ? .on : .off
        }
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        selectedLanguage = code
        speechEngine.languageCode = code.isEmpty ? nil : code

        for item in languageItems {
            item.state = (item.representedObject as? String) == code ? .on : .off
        }
    }

    @objc private func changeModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        selectedModel = name
        speechEngine.changeModel(name)

        for item in modelItems {
            item.state = (item.representedObject as? String) == name ? .on : .off
        }
    }

    @objc private func quit() {
        keyMonitor.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            VoiceInput needs Accessibility permission to monitor the hotkey.

            1. Open System Settings → Privacy & Security → Accessibility
            2. Add and enable VoiceInput
            3. Restart the app
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
