import AVFoundation
import Foundation
import Observation

/// Live captions while recording, with Amazon Transcribe streaming. Only the microphone is streamed;
/// the full transcript (including system audio) still comes from the pass after recording.
@Observable
@MainActor
final class LiveTranscriber {
    private(set) var segments: [TranscriptSegment] = []
    private(set) var partial = ""
    private(set) var errorMessage: String?

    private var stream: TranscribeStream?
    private let results = ResultCollector()
    private let converter = PCM16()
    private let pauseLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var paused = false
    @ObservationIgnored nonisolated(unsafe) private var droppedAudio = false
    private var wasPaused = false

    static var isEnabled: Bool {
        let provider = Prefs.transcriptionProvider
        return TranscribeSettings.liveEnabled && (provider == .amazonTranscribe || provider == .bedrock)
    }

    func start() {
        let results = results
        let stream = TranscribeStream { [weak self] update in
            results.add(update.finals)
            let finals = TranscribeParsing.streamingSegments(update.finals, offset: 0, track: "Me")
            Task { @MainActor in
                guard let self else { return }
                self.segments += finals
                self.partial = update.partial ?? (finals.isEmpty ? self.partial : "")
            }
        }
        do {
            try stream.start()
            self.stream = stream
            Task { [weak self] in
                do {
                    try await stream.wait()
                } catch {
                    guard let self, self.stream === stream else { return }
                    self.errorMessage = AIError.describe(error)
                }
            }
        } catch {
            errorMessage = AIError.describe(error)
        }
    }

    nonisolated func feedFromCaptureQueue(_ buffer: AVAudioPCMBuffer, stream: TranscribeStream?, converter: PCM16) {
        guard let stream, var data = converter.convert(buffer) else { return }
        pauseLock.lock()
        if paused { data = Data(count: data.count) } // Silence keeps the stream open while paused.
        let accepted = stream.send(data)
        if !accepted { droppedAudio = true }
        pauseLock.unlock()
        if !accepted {
            Task { @MainActor [weak self] in
                guard let self, self.stream === stream else { return }
                self.fail("Amazon Transcribe stopped accepting microphone audio. The recording is still saved.")
            }
        }
    }

    /// A closure the microphone can call on its own queue.
    var audioSink: (AVAudioPCMBuffer) -> Void {
        let stream = stream
        let converter = converter
        return { [weak self] buffer in
            self?.feedFromCaptureQueue(buffer, stream: stream, converter: converter)
        }
    }

    func setPaused(_ value: Bool) {
        if value { wasPaused = true }
        pauseLock.lock()
        paused = value
        pauseLock.unlock()
    }

    func fail(_ message: String) {
        stream?.cancel()
        stream = nil
        partial = ""
        errorMessage = message
    }

    private func hadAudioLoss() -> Bool {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        return droppedAudio
    }

    /// Returns reusable microphone segments only when the live timebase matches the saved audio.
    func finish(reuse: Bool) async -> [TranscriptSegment] {
        guard let stream else { return [] }
        self.stream = nil
        defer { partial = "" }
        guard reuse, !wasPaused, !hadAudioLoss(), errorMessage == nil else {
            stream.cancel()
            return []
        }
        do {
            try await stream.finish()
            return TranscribeParsing.streamingSegments(results.results, offset: 0, track: "Me")
        } catch {
            errorMessage = AIError.describe(error)
            return []
        }
    }
}
