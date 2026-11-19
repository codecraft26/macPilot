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
    private let converter = PCM16()
    private let pauseLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var paused = false

    static var isAvailable: Bool {
        Prefs.transcriptionProvider == .amazonTranscribe && TranscribeSettings.liveEnabled && TranscribeSettings.hasAccessKeys
    }

    func start() {
        let stream = TranscribeStream { [weak self] update in
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
        } catch {
            errorMessage = AIError.describe(error)
        }
    }

    nonisolated func feedFromCaptureQueue(_ buffer: AVAudioPCMBuffer, stream: TranscribeStream?, converter: PCM16) {
        guard let stream, var data = converter.convert(buffer) else { return }
        pauseLock.lock()
        let isPaused = paused
        pauseLock.unlock()
        if isPaused { data = Data(count: data.count) } // silence keeps the stream open while paused
        stream.send(data)
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
        pauseLock.lock()
        paused = value
        pauseLock.unlock()
    }

    /// Ends the stream and waits briefly for the last results.
    func finish() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await stream.finish() }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    stream.cancel()
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            if segments.isEmpty { errorMessage = AIError.describe(error) }
        }
        partial = ""
    }
}
