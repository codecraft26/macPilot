import AppKit
import AVFoundation
import Observation
import Speech
import SwiftData

/// The talking buddy: listens (on-device speech recognition), runs commands or asks the AI,
/// and answers out loud with an on-device voice.
@Observable
@MainActor
final class PilotVoice: NSObject {
    static let shared = PilotVoice()

    enum Phase: Equatable { case idle, listening, thinking, speaking }

    private(set) var phase: Phase = .idle
    /// What it heard (live while listening).
    private(set) var heard = ""
    /// What it answered (shown in the speech bubble).
    private(set) var reply = ""
    private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var lastHeardAt = Date()
    private var listenStarted = Date()
    private var watchdog: Timer?
    private var task: Task<Void, Never>?
    private var hideBubble: Task<Void, Never>?
    private var history: [ChatTurn] = []

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    var showsBubble: Bool { phase != .idle || !reply.isEmpty }

    // MARK: Listen

    /// Click on the buddy: start listening, or stop and answer, or interrupt speaking.
    func toggle() {
        switch phase {
        case .idle: Task { await listen() }
        case .listening: finishListening()
        case .speaking, .thinking: stopAll()
        }
    }

    func listen() async {
        guard phase == .idle else { return }
        WakeWordListener.shared.pause()
        hideBubble?.cancel()
        reply = ""
        heard = ""
        guard await Self.requestPermissions() else {
            say("I need Microphone and Speech Recognition permission. Allow MacPilot in System Settings, Privacy and Security.")
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            say("Speech recognition isn't available right now.")
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            let level = Self.rms(buffer)
            Task { @MainActor in PilotVoice.shared.level = level }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            say("I couldn't use the microphone.")
            return
        }
        NSSound(named: "Tink")?.play()
        phase = .listening
        listenStarted = Date()
        lastHeardAt = Date()
        FloatingBuddy.shared.updateSize()
        recognition = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                let voice = PilotVoice.shared
                guard voice.phase == .listening else { return }
                if let text, text != voice.heard {
                    voice.heard = text
                    voice.lastHeardAt = Date()
                }
                if isFinal || error != nil { voice.finishListening() }
            }
        }
        // Stop after a short pause once something was said, or give up if nothing is said.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let voice = PilotVoice.shared
                guard voice.phase == .listening else { return }
                let now = Date()
                if !voice.heard.isEmpty && now.timeIntervalSince(voice.lastHeardAt) > 1.4 { voice.finishListening() }
                else if voice.heard.isEmpty && now.timeIntervalSince(voice.listenStarted) > 7 { voice.finishListening() }
                else if now.timeIntervalSince(voice.listenStarted) > 30 { voice.finishListening() }
            }
        }
    }

    func finishListening() {
        guard phase == .listening else { return }
        watchdog?.invalidate()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        level = 0
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            phase = .idle
            say("I didn't catch that.")
            return
        }
        phase = .thinking
        task = Task { await handle(PilotCommand.parse(text)) }
    }

    func stopAll() {
        task?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        if phase == .listening {
            watchdog?.invalidate()
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            recognition?.cancel()
        }
        phase = .idle
        reply = ""
        FloatingBuddy.shared.updateSize()
        WakeWordListener.shared.resume()
    }

    // MARK: Commands

    private func handle(_ command: PilotCommand) async {
        let context = Persistence.container.mainContext
        switch command {
        case .cancel:
            stopAll()
        case .hide:
            say("Okay, hiding. Bring me back from the menu bar.")
            try? await Task.sleep(for: .seconds(2))
            FloatingBuddy.shared.setEnabled(false)
        case let .addTask(title, due):
            let item = TaskItem(title: title, dueDate: due)
            context.insert(item)
            try? context.save()
            NotificationService.schedule(id: item.notificationID, title: item.title, at: item.dueDate)
            say("Added \(title)" + (due.map { ", due \(Self.spoken($0))." } ?? " to your tasks."))
        case .startMeeting:
            if RecordingManager.shared.isActive { say("I'm already recording.") } else {
                RecordingManager.shared.toggleMeeting()
                say("Recording the meeting. Say stop recording when you're done.")
            }
        case .stopRecording:
            if RecordingManager.shared.isActive {
                await RecordingManager.shared.stop()
                say("Stopped. I'll transcribe and summarize it.")
            } else { say("Nothing is recording.") }
        case .voiceNote:
            await RecordingManager.shared.start(kind: .voiceNote, title: "Voice note \(Date().formatted(date: .abbreviated, time: .shortened))")
            say("Recording a voice note. Click me or say stop recording to finish.")
        case .newNote(let text):
            let note = Note(title: "", body: text)
            context.insert(note)
            try? context.save()
            if text.isEmpty {
                WindowManager.shared.open(.notes, action: .openNote(note.uid))
                say("Here's a new note.")
            } else {
                say("Saved the note.")
            }
        case .today:
            say(Self.todaySummary(context: context))
        case let .timer(seconds, label):
            NotchTimers.shared.start(seconds: seconds, label: label)
            say("Timer set for \(TimerParser.describe(seconds).replacingOccurrences(of: " min", with: " minutes").replacingOccurrences(of: " h", with: " hours")).")
        case .open(let section):
            WindowManager.shared.showDashboard(section: section)
            say("Opening \(section.title).")
        case .dictate:
            say("Start talking after the sound. I'll type it where your cursor is.")
            try? await Task.sleep(for: .seconds(2.5))
            FloatingBuddy.shared.toggleDictation()
        case .smartReminder(let words):
            if let draft = await ReminderInput.parse(words) {
                ReminderEngine.shared.add(draft, source: words)
                say("Okay. \(draft.trigger.summary), I'll remind you to \(draft.text.prefix(1).lowercased() + draft.text.dropFirst()).")
            } else {
                say("I couldn't work out when to remind you. Try: remind me to check reviews when I open Xcode.")
            }
        case .speedTest:
            say("Running a speed test. It takes about twenty seconds.")
            if let result = await SpeedTest.shared.run() {
                say(result.spoken)
            } else {
                say(SpeedTest.shared.lastError ?? "The speed test didn't finish.")
            }
        case .chat(let text):
            await answer(text)
        }
    }

    private func answer(_ question: String) async {
        let provider = Prefs.analysisProvider
        history.append(ChatTurn(role: .user, content: question))
        history = Array(history.suffix(8))
        var text = ""
        do {
            for try await chunk in AIRouter.stream(provider: provider, model: Prefs.model(for: provider), system: Self.systemPrompt, turns: history) {
                if case .text(let piece) = chunk { text += piece }
                if case let .usage(input, output) = chunk { UsageTracker.record(provider, input: input, output: output) }
            }
        } catch {
            say("I couldn't reach the AI. \(AIError.describe(error))")
            return
        }
        guard !Task.isCancelled else { return }
        let clean = Self.speakable(text)
        history.append(ChatTurn(role: .assistant, content: clean))
        say(clean)
    }

    static let systemPrompt = """
    You are Pilot, a friendly voice assistant living on the user's Mac (part of MacPilot). Your reply is spoken aloud: \
    answer in one to three short sentences of plain speech — no Markdown, lists, code blocks or emoji. \
    If something needs a long answer, give the gist and suggest opening the assistant with Option-Space.
    """

    /// Removes Markdown so the voice doesn't read symbols aloud.
    nonisolated static func speakable(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " (code omitted) ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^\s*[-•]\s+"#, with: "", options: .regularExpression)
        return result.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func todaySummary(context: ModelContext, now: Date = Date()) -> String {
        let events = CalendarService.shared.events(on: now).filter { !$0.isAllDay && $0.end > now }.sorted { $0.start < $1.start }
        let open = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isCompleted }))) ?? []
        let calendar = Calendar.current
        let dueToday = open.filter { $0.dueDate.map(calendar.isDateInToday) ?? false }
        let overdue = open.filter { ($0.dueDate ?? .distantFuture) < calendar.startOfDay(for: now) }
        var parts: [String] = []
        if let next = events.first {
            let when = next.start <= now ? "now" : "at \(next.start.formatted(date: .omitted, time: .shortened))"
            parts.append("Next up is \(next.title) \(when).")
            if events.count > 1 { parts.append("You have \(events.count) meetings left today.") }
        } else {
            parts.append(CalendarService.shared.isConnected ? "No more meetings today." : "Your calendar isn't connected yet.")
        }
        if !dueToday.isEmpty {
            parts.append("\(dueToday.count) task\(dueToday.count == 1 ? "" : "s") due today, starting with \(dueToday[0].title).")
        }
        if !overdue.isEmpty { parts.append("And \(overdue.count) overdue.") }
        if dueToday.isEmpty && overdue.isEmpty { parts.append("No tasks due today.") }
        return parts.joined(separator: " ")
    }

    private static func spoken(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = calendar.component(.hour, from: date) == 0 && calendar.component(.minute, from: date) == 0
            ? "" : " at \(date.formatted(date: .omitted, time: .shortened))"
        if calendar.isDateInToday(date) { return "today" + time }
        if calendar.isDateInTomorrow(date) { return "tomorrow" + time }
        return date.formatted(.dateTime.weekday(.wide).month().day()) + time
    }

    // MARK: Speak

    func say(_ text: String) {
        reply = text
        hideBubble?.cancel()
        FloatingBuddy.shared.updateSize()
        guard UserDefaults.standard.bool(forKey: PrefKey.pilotSpeaks), !text.isEmpty else {
            phase = .idle
            scheduleBubbleHide(after: 6)
            return
        }
        phase = .speaking
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }

    private func scheduleBubbleHide(after seconds: Double) {
        hideBubble?.cancel()
        hideBubble = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, phase == .idle else { return }
            reply = ""
            heard = ""
            FloatingBuddy.shared.updateSize()
            WakeWordListener.shared.resume()
        }
    }

    /// The nicest installed voice for the current language (premium or enhanced if downloaded).
    static var bestVoice: AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    // MARK: Helpers

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && mic
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
    }
}

extension PilotVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let voice = PilotVoice.shared
            guard voice.phase == .speaking else { return }
            voice.phase = .idle
            voice.scheduleBubbleHide(after: 5)
        }
    }
}

/// Optional "Hey Pilot": listens continuously with on-device recognition only (never sent to a server),
/// and only while nothing else is using the microphone. Off by default.
@MainActor
final class WakeWordListener {
    static let shared = WakeWordListener()

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var paused = false
    private(set) var isRunning = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: PrefKey.pilotWakeWord) }

    func start() {
        stop()
        guard Self.isEnabled, FloatingBuddy.isEnabled else { return }
        paused = false
        Task {
            guard await PilotVoice.requestPermissions() else { return }
            begin()
        }
        // Recognition sessions are limited to about a minute; restart regularly.
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { _ in
            MainActor.assumeIsolated { WakeWordListener.shared.restartIfIdle() }
        }
    }

    func stop() {
        restartTimer?.invalidate()
        restartTimer = nil
        end()
    }

    func pause() {
        paused = true
        end()
    }

    func resume() {
        guard Self.isEnabled, paused else { return }
        paused = false
        begin()
    }

    private func restartIfIdle() {
        guard !paused else { return }
        end()
        begin()
    }

    private func begin() {
        guard !isRunning, !paused, Self.isEnabled,
              !RecordingManager.shared.isActive, !DictationController.shared.phase.isActive,
              PilotVoice.shared.phase == .idle,
              let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch { return }
        isRunning = true
        recognition = recognizer.recognitionTask(with: request) { result, _ in
            guard let text = result?.bestTranscription.formattedString.lowercased() else { return }
            if WakeWordListener.containsWakeWord(text) {
                Task { @MainActor in
                    WakeWordListener.shared.pause()
                    await PilotVoice.shared.listen()
                }
            }
        }
    }

    private func end() {
        guard isRunning else { return }
        recognition?.cancel()
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
    }

    nonisolated static func containsWakeWord(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["hey pilot", "hi pilot", "ok pilot", "okay pilot", "hey, pilot"].contains { lower.contains($0) }
    }
}
