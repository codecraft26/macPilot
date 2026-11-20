import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftData

/// ⌥D voice dictation: hold to talk (or tap for hands-free), then the text is transcribed,
/// cleaned up and pasted at the cursor in the app you were using.
@Observable
@MainActor
final class DictationController {
    static let shared = DictationController()

    enum Phase: Equatable {
        case idle, starting, listening, transcribing, cleaning
        case done(String)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .idle, .done, .failed: return false
            default: return true
            }
        }
    }

    private(set) var phase: Phase = .idle
    var mode: DictationMode = .plain
    private(set) var level: Float = 0
    private(set) var startedAt: Date?
    private(set) var handsFree = false
    /// Live words while speaking (Amazon Transcribe streaming only).
    var partialText: String {
        guard let live else { return "" }
        let finals = live.segments.map(\.text).joined(separator: " ")
        return [finals, live.partial].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var keyState = DictationKeyState()
    private var mic: MicRecorder?
    private var live: LiveTranscriber?
    private var fileURL: URL?
    private var targetApp: NSRunningApplication?
    private var meterTimer: Timer?
    private var escapeMonitor: Any?
    private var hideTask: Task<Void, Never>?
    private var sessionID = UUID()

    private init() {}

    // MARK: Hotkey

    func hotKeyDown(mode: DictationMode) {
        if case .transcribing = phase { return }
        if case .cleaning = phase { return }
        let pushToTalk = UserDefaults.standard.bool(forKey: PrefKey.dictationPushToTalk)
        switch keyState.keyDown(at: Date(), pushToTalk: pushToTalk) {
        case .start:
            self.mode = mode
            handsFree = !pushToTalk
            Task { await start() }
        case .stop:
            finish()
        case .none:
            break
        }
    }

    func hotKeyUp() {
        let action = keyState.keyUp(at: Date())
        handsFree = keyState.phase == .handsFree
        if action == .stop { finish() }
    }

    // MARK: Lifecycle

    private func start() async {
        hideTask?.cancel()
        phase = .starting
        sessionID = UUID()
        DictationHUD.shared.show()

        guard await MicRecorder.requestAccess() else {
            fail(RecorderError.microphoneDenied.localizedDescription)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        targetApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? WindowManager.shared.previousApp : front

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacPilot-Dictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("dictation-\(UUID().uuidString).m4a")
        fileURL = url

        let mic = MicRecorder()
        if Prefs.transcriptionProvider == .amazonTranscribe, BedrockConfig.authMethod == .accessKeys, BedrockConfig.isConfigured {
            let live = LiveTranscriber()
            live.start()
            mic.onAudio = live.audioSink
            self.live = live
        }
        do {
            try mic.start(deviceID: Prefs.microphoneID, url: url)
        } catch {
            fail(error.localizedDescription)
            return
        }
        // A key-up may already have stopped this session while the mic was starting.
        guard keyState.phase != .idle else {
            self.mic = mic
            finish()
            return
        }
        self.mic = mic
        startedAt = Date()
        phase = .listening
        if !RecordingManager.shared.isActive { AppState.shared.isRecording = true }
        playSound("Tink")
        startMeter()
        installEscapeMonitor()
    }

    /// Esc (or the HUD's ✕) throws the dictation away.
    func cancel() {
        let mic = mic
        let live = live
        tearDown()
        Task {
            await mic?.stop()
            _ = await live?.finish(reuse: false)
            removeTemporaryFile()
        }
        phase = .idle
        DictationHUD.shared.hide()
    }

    /// Stop listening and process what was said.
    func finish() {
        guard let mic else {
            keyState.reset()
            return
        }
        let live = live
        let started = startedAt ?? Date()
        let session = sessionID
        tearDown()
        playSound("Pop")
        phase = .transcribing

        Task {
            await mic.stop()
            let duration = Date().timeIntervalSince(started)
            guard duration > 0.4 else {
                _ = await live?.finish(reuse: false)
                removeTemporaryFile()
                cancelQuietly()
                return
            }
            do {
                let raw = try await transcribe(live: live)
                guard session == sessionID else { return }
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    fail("No speech was detected.")
                    return
                }
                let text = await cleanUp(raw)
                deliver(text, raw: raw)
            } catch {
                fail(AIError.describe(error))
            }
            removeTemporaryFile()
        }
    }

    // MARK: Steps

    private func transcribe(live: LiveTranscriber?) async throws -> String {
        if let live {
            let segments = await live.finish(reuse: true)
            let text = segments.map(\.text).joined(separator: " ")
            if !text.isEmpty { return text }
        }
        guard let fileURL else { throw TranscriptionError.noAudio }
        let segments = try await TranscriptionService.transcribe(fileURL, speaker: "Me", offset: 0, provider: Prefs.transcriptionProvider)
        return segments.map(\.text).joined(separator: " ")
    }

    private func cleanUp(_ raw: String) async -> String {
        let useAI = UserDefaults.standard.bool(forKey: PrefKey.dictationCleanup) || mode != .plain
        guard useAI, Prefs.isEnabled(Prefs.analysisProvider) else { return FillerRemover.clean(raw) }
        phase = .cleaning
        do {
            let language = UserDefaults.standard.string(forKey: PrefKey.dictationLanguage) ?? "English"
            let reply = try await AIRouter.complete(
                provider: Prefs.analysisProvider,
                system: DictationPrompt.system(mode: mode, language: language, vocabulary: Prefs.dictationVocabulary),
                prompt: raw
            )
            let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? FillerRemover.clean(raw) : cleaned
        } catch {
            return FillerRemover.clean(raw)
        }
    }

    private func deliver(_ text: String, raw: String) {
        let context = Persistence.container.mainContext
        var appName = targetApp?.localizedName ?? ""
        var message = text

        if mode == .task {
            let task = TaskItem(title: text.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), dueDate: DateParsing.firstDate(in: text))
            task.notes = "Dictated: \(raw)"
            context.insert(task)
            try? context.save()
            NotificationService.schedule(id: task.notificationID, title: task.title, at: task.dueDate)
            appName = "Tasks"
            message = "Task added: \(task.title)"
        } else if UserDefaults.standard.bool(forKey: PrefKey.dictationAutoPaste) {
            let keepClipboard = UserDefaults.standard.bool(forKey: PrefKey.dictationKeepClipboard)
            let snapshot = keepClipboard ? PasteboardSnapshot.capture() : nil
            if PasteService.paste(text: text, into: targetApp) {
                if let snapshot {
                    // Give the target app time to read the pasteboard, then put the user's clipboard back.
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        snapshot.restore()
                        ClipboardMonitor.shared.ignoreCurrentChange()
                    }
                }
            } else {
                message = "Copied. Press ⌘V to paste (allow MacPilot in Accessibility to paste automatically)."
                targetApp?.activate()
            }
        } else {
            PasteService.write(text: text)
            message = "Copied to the clipboard."
        }

        if UserDefaults.standard.bool(forKey: PrefKey.dictationSaveNote) && mode != .task {
            let note = Note(title: "", body: text, folder: "Dictation")
            context.insert(note)
            try? context.save()
        }
        DictationHistory.add(DictationEntry(text: text, raw: raw, mode: mode, app: appName, date: Date()))
        phase = .done(message)
        scheduleHide(after: 1.6)
    }

    // MARK: Helpers

    private func tearDown() {
        mic = nil
        live = nil
        keyState.reset()
        handsFree = false
        stopMeter()
        removeEscapeMonitor()
        level = 0
        if !RecordingManager.shared.isActive { AppState.shared.isRecording = false }
    }

    private func fail(_ message: String) {
        let mic = mic
        tearDown()
        Task { await mic?.stop() }
        removeTemporaryFile()
        phase = .failed(message)
        scheduleHide(after: 3.5)
    }

    private func cancelQuietly() {
        phase = .idle
        DictationHUD.shared.hide()
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, !phase.isActive else { return }
            phase = .idle
            DictationHUD.shared.hide()
        }
    }

    private func removeTemporaryFile() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    private func playSound(_ name: String) {
        guard UserDefaults.standard.bool(forKey: PrefKey.dictationSounds) else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func startMeter() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level = self.mic?.level ?? 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        // Global key monitoring needs Accessibility; without it, use the HUD's ✕ button.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in DictationController.shared.cancel() }
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
