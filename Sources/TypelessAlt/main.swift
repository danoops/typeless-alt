import AppKit
import AVFoundation
import ApplicationServices
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate {
    var status: NSStatusItem!
    var settings = Settings()
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var recorder: AVAudioRecorder?
    var recordingURL: URL?
    var timer: Timer?
    var activeBackend: DictationBackend?
    var busy = false
    var requesting = false
    var targetPID: pid_t?
    var targetElement: AXUIElement?
    var targetBundle = ""
    var lastText = ""
    var state = "Idle"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        do { settings = try Settings.load(); try registerHotKey() } catch { alert(error.localizedDescription) }
        update("Idle")
        if !AXIsProcessTrusted() {
            alert("Welcome to Typeless Alt. Enable Accessibility to paste dictation into other apps. Use the menu → Grant Accessibility, then enable Typeless Alt in System Settings. Microphone access is requested on your first recording. Audio and transcript are sent to the selected cloud providers using your credentials.")
        }
    }
    func update(_ value: String) {
        state = value
        let symbol = recorder != nil ? "record.circle.fill" : busy ? "ellipsis.circle" : "mic"
        status.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: value)
        status.button?.contentTintColor = recorder != nil ? .systemRed : nil
        status.button?.toolTip = "Typeless Alt — \(value)"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "\(settings.backend) — \(value)", action: nil, keyEquivalent: ""))
        add(menu, recorder == nil ? "Start dictation" : "Stop and insert", #selector(toggle))
        if recorder != nil { add(menu, "Cancel recording", #selector(cancel)) }
        menu.addItem(.separator())
        add(menu, "Copy last result", #selector(copyLast))
        add(menu, "Grant Accessibility…", #selector(accessibility))
        add(menu, "Open settings.plist…", #selector(openSettings))
        add(menu, "Reload settings", #selector(reload))
        add(menu, "Open local data folder", #selector(openData))
        menu.addItem(.separator())
        add(menu, "Quit", #selector(quit))
        status.menu = menu
    }
    func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
    }
    func registerHotKey() throws {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context = context else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { delegate.toggle() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { throw Failure("Could not install hotkey handler: \(result)") }
        }
        if let old = hotKey { UnregisterEventHotKey(old); hotKey = nil }
        let result = RegisterEventHotKey(settings.keyCode, settings.modifiers, EventHotKeyID(signature: 0x54595045, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        guard result == noErr else { throw Failure("Hotkey unavailable (\(result)). Change keyCode/modifiers in settings.plist and Reload settings.") }
    }
    func focusedElement(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    @objc func toggle() {
        guard !busy, !requesting else { return }
        if recorder != nil { stop(); return }
        guard AXIsProcessTrusted() else { accessibility(); return }
        do { activeBackend = try DictationBackend(settings) } catch { alert(error.localizedDescription); return }
        let app = NSWorkspace.shared.frontmostApplication
        targetPID = app?.processIdentifier; targetBundle = app?.bundleIdentifier ?? ""
        targetElement = targetPID.flatMap { focusedElement($0) }
        guard targetPID != ProcessInfo.processInfo.processIdentifier, targetElement != nil else {
            alert("Focus a text field in another app, then press the global hotkey."); return
        }
        requesting = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.requesting = false
                guard granted else { self.alert("Microphone denied. Enable Typeless Alt in System Settings → Privacy & Security → Microphone, then retry."); return }
                self.start()
            }
        }
    }
    func start() {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("typeless-alt-\(UUID().uuidString).m4a")
            recordingURL = url
            let audio = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            audio.delegate = self
            guard audio.record() else { throw Failure("Could not start default microphone recording.") }
            recorder = audio
            if settings.sounds { NSSound(named: "Tink")?.play() }
            timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in self?.stop() }
            update("Recording — press hotkey to stop (max 3 min)")
        } catch { cleanup(); alert(error.localizedDescription) }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        guard let audio = recorder, let url = recordingURL else { return }
        let duration = audio.currentTime
        recorder = nil; audio.stop(); busy = true
        if settings.sounds { NSSound(named: "Pop")?.play() }
        update("Processing…")
        Task { @MainActor in
            defer { self.cleanup(); self.busy = false; self.update("Idle") }
            do {
                guard duration > 0.35 else { throw Failure("Recording too short.") }
                guard let api = activeBackend else { throw Failure("No active backend.") }
                let transcript = try await api.transcribe(url)
                guard !transcript.isEmpty else { throw Failure("No speech detected.") }
                lastText = transcript // recoverable if polishing fails
                let result: String
                do { result = try await api.polish(transcript, bundleID: targetBundle) }
                catch { throw Failure("Polishing failed: \(error.localizedDescription) Raw transcript is available via Copy last result; nothing was inserted.") }
                lastText = result
                var historyWarning: String?
                do { try saveHistory(result, limit: settings.historyLimit) } catch { historyWarning = "History could not be saved: \(error.localizedDescription)" }
                try await insert(result)
                if let warning = historyWarning { alert(warning) }
            } catch { alert(error.localizedDescription) }
        }
    }
    func insert(_ text: String) async throws {
        // Never steal focus or insert into an app the user switched to while waiting.
        guard AXIsProcessTrusted(), let pid = targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let original = targetElement, let current = focusedElement(pid), CFEqual(original, current) else {
            throw Failure("Focus changed or Accessibility is unavailable. Nothing inserted. Focus the intended field and use Copy last result, then ⌘V.")
        }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
        guard (role as? String) != "AXSecureTextField" else { throw Failure("Password fields are not supported. Result remains in Copy last result.") }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        guard let source = CGEventSource(stateID: .combinedSessionState), let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw Failure("Could not create paste event. Use Copy last result.") }
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // CGEvent cannot confirm application acceptance. Give apps time to read the clipboard.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if pasteboard.changeCount == changeCount { pasteboard.clearContents(); if !saved.isEmpty { pasteboard.writeObjects(saved) } }
    }
    func cleanup() {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        activeBackend = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }; recordingURL = nil
        if status != nil { update("Idle") }
    }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        cleanup(); alert(error?.localizedDescription ?? "Audio recording failed.")
    }
    @objc func cancel() { cleanup() }
    @objc func copyLast() {
        guard !lastText.isEmpty else { alert("No result yet."); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lastText, forType: .string)
    }
    @objc func accessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func openSettings() { NSWorkspace.shared.open(Settings.url) }
    @objc func openData() { NSWorkspace.shared.open(support) }
    @objc func reload() {
        guard recorder == nil, !busy else { return }
        do { settings = try Settings.load(); try registerHotKey(); update("Idle — settings loaded") } catch { alert(error.localizedDescription) }
    }
    @objc func quit() { guard !busy else { alert("Wait for processing to finish before quitting."); return }; cleanup(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { cleanup() }
    func alert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Typeless Alt"; alert.informativeText = message; alert.runModal()
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
