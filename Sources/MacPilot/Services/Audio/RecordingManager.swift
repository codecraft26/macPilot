import AVFoundation
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

/// Owns the single active recording (voice note or meeting), its pause/resume state and level meter,
/// and keeps the menu bar indicator in sync. Nothing is ever recorded without a visible indicator.
@Observable
@MainActor
final class RecordingManager {
    static let shared = RecordingManager()

    enum State: Equatable {
        case idle, starting, recording, paused, stopping
    }

    private(set) var state: State = .idle
    private(set) var current: Recording?
    private(set) var level: Float = 0
    /// Non-fatal information about the current recording (e.g. system audio unavailable).
    var notice: String?
    var errorMessage: String?

    private var mic: MicRecorder?
    private var system: SystemAudioRecorder?
    private var activeSince: Date?
    private var accumulated: TimeInterval = 0
    private var meterTimer: Timer?

    private var context: ModelContext { Persistence.container.mainContext }

    private init() {}

    var isActive: Bool { state != .idle }
    var isPaused: Bool { state == .paused }

    /// Recorded time, excluding pauses.
    func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulated + (activeSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    // MARK: Start

    /// ⌥R and the menu bar: start a meeting recording (linked to the current calendar event if there is one) or stop.
    func toggleMeeting() {
        if isActive {
            Task { await stop() }
        } else {
            let event = CalendarService.shared.currentOrImminentEvent()
            Task {
                await start(
                    kind: .meeting,
                    title: event?.title ?? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))",
                    eventID: event?.calendarItemIdentifier,
                    attendees: event.map(CalendarService.attendeeNames) ?? ""
                )
            }
        }
    }

    func start(kind: RecordingKind, title: String, eventID: String? = nil, attendees: String = "", prepNotes: String = "") async {
        guard state == .idle else {
            errorMessage = RecorderError.alreadyRecording.localizedDescription
            return
        }
        errorMessage = nil
        notice = nil
        state = .starting

        guard await MicRecorder.requestAccess() else {
            fail(RecorderError.microphoneDenied)
            return
        }

        let recording = Recording(kind: kind, title: title, calendarEventID: eventID, attendees: attendees)
        recording.prepNotes = prepNotes
        recording.micFileName = "microphone.m4a"
        context.insert(recording)
        try? context.save()

        let mic = MicRecorder()
        do {
            try mic.start(deviceID: Prefs.microphoneID, url: recording.folderURL.appendingPathComponent("microphone.m4a"))
        } catch {
            context.delete(recording)
            RecordingStorage.deleteFiles(for: recording.uid)
            try? context.save()
            fail(error)
            return
        }
        self.mic = mic
        current = recording
        accumulated = 0
        activeSince = Date()
        state = .recording
        AppState.shared.isRecording = true
        startMeter()

        if kind == .meeting && Prefs.includeSystemAudio {
            await startSystemAudio(for: recording)
        }
    }

    private func startSystemAudio(for recording: Recording) async {
        guard SystemAudioRecorder.hasPermission || SystemAudioRecorder.requestPermission() else {
            let message = "System audio is not being recorded because MacPilot has no Screen Recording permission (System Settings → Privacy & Security → Screen & System Audio Recording). Recording continues with the microphone only."
            notice = message
            recording.notice = message
            return
        }
        let recorder = SystemAudioRecorder()
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in
                let message = "System audio stopped: \(error.localizedDescription). The microphone is still recording."
                self?.notice = message
                self?.current?.notice = message
            }
        }
        do {
            try await recorder.start(url: recording.folderURL.appendingPathComponent("system.m4a"))
            system = recorder
            recording.systemFileName = "system.m4a"
        } catch {
            let message = "System audio could not be captured (\(error.localizedDescription)). Recording continues with the microphone only."
            notice = message
            recording.notice = message
        }
    }

    // MARK: Pause / resume / stop

    func pause() {
        guard state == .recording else { return }
        mic?.pause()
        system?.pause()
        if let since = activeSince { accumulated += Date().timeIntervalSince(since) }
        activeSince = nil
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        mic?.resume()
        system?.resume()
        activeSince = Date()
        state = .recording
    }

    func togglePause() {
        state == .paused ? resume() : pause()
    }

    func stop() async {
        guard state == .recording || state == .paused, let recording = current else { return }
        let total = elapsed()
        state = .stopping
        stopMeter()

        await mic?.stop()
        let micStart = mic?.startedAt
        if let system {
            let systemStart = await system.startDate()
            if await system.stop() {
                if let micStart, let systemStart {
                    recording.systemAudioOffset = max(0, systemStart.timeIntervalSince(micStart))
                }
            } else {
                recording.systemFileName = nil
            }
        }

        recording.duration = total
        recording.status = .recorded
        try? context.save()

        mic = nil
        system = nil
        activeSince = nil
        accumulated = 0
        current = nil
        level = 0
        state = .idle
        AppState.shared.isRecording = false

        if Prefs.autoProcessRecordings {
            RecordingProcessor.process(recording)
        }
    }

    // MARK: Import

    static let importableTypes: [UTType] = ["mp3", "wav", "m4a", "flac", "ogg", "aac", "mp4", "aiff"]
        .compactMap { UTType(filenameExtension: $0) }

    @discardableResult
    func importAudio(from url: URL) async -> Recording? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let recording = Recording(kind: .imported, title: url.deletingPathExtension().lastPathComponent)
        let fileName = "imported." + (url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased())
        let destination = recording.folderURL.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            RecordingStorage.deleteFiles(for: recording.uid)
            errorMessage = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
        recording.micFileName = fileName
        recording.duration = await AudioTools.duration(of: destination) ?? 0
        recording.status = .recorded
        context.insert(recording)
        try? context.save()
        if Prefs.autoProcessRecordings {
            RecordingProcessor.process(recording)
        }
        return recording
    }

    // MARK: Helpers

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        state = .idle
        AppState.shared.isRecording = false
    }

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.level = self.state == .recording ? (self.mic?.level ?? 0) : 0
            }
        }
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }
}

extension Recording {
    /// Label for the microphone (or imported) track in new transcripts.
    var speakerLabelForMic: String { kind == .imported ? "Speaker" : "Me" }
}

enum AudioTools {
    static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration), time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}

/// Cleans up state left behind if MacPilot quit or crashed mid-recording or mid-processing.
@MainActor
enum RecordingRecovery {
    static func markInterrupted(context: ModelContext) {
        guard let recordings = try? context.fetch(FetchDescriptor<Recording>()) else { return }
        var changed = false
        for recording in recordings {
            switch recording.status {
            case .recording:
                recording.status = recording.audioURLs.isEmpty ? .failed : .recorded
                recording.notice = "MacPilot quit while this was recording; the audio may be incomplete."
                Task { @MainActor in
                    if let url = recording.micURL, let duration = await AudioTools.duration(of: url) {
                        recording.duration = duration
                        try? context.save()
                    }
                }
                changed = true
            case .transcribing:
                recording.status = .recorded
                changed = true
            case .analyzing:
                recording.status = .transcribed
                changed = true
            default:
                break
            }
        }
        if changed { try? context.save() }
    }
}
