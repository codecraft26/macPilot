import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Captures the audio other apps play (for example the remote side of a call) with an
/// audio-only ScreenCaptureKit stream and writes it to an AAC .m4a file.
/// Requires Screen Recording permission. MacPilot's own audio is excluded.
/// Mutable state is confined to `queue`; setup and teardown happen on the caller's task.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.macpilot.system-audio")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var url: URL?

    // Accessed only on `queue`.
    private var sessionStarted = false
    private var isPaused = false
    private var pauseStartedAt: CMTime?
    private var pausedTotal = CMTime.zero
    private var firstSampleDate: Date?

    /// Called on an arbitrary queue if capture stops unexpectedly.
    var onUnexpectedStop: ((Error) -> Void)?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; returns the current permission.
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func start(url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96_000
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw AVError(.unknown) }
        writer.add(input)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Audio only: keep the (required) video side as small and slow as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        guard writer.startWriting() else { throw writer.error ?? AVError(.unknown) }
        self.writer = writer
        self.input = input
        self.url = url
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            self.stream = nil
            throw error
        }
    }

    func pause() { queue.async { self.isPaused = true } }
    func resume() { queue.async { self.isPaused = false } }

    /// When the first audio sample was written, if any.
    func startDate() async -> Date? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.firstSampleDate) }
        }
    }

    /// Stops capture and finishes the file. Returns false when no audio was captured (the file is removed).
    func stop() async -> Bool {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        let started: Bool = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.sessionStarted) }
        }
        guard let writer, let input else { return false }
        if started {
            input.markAsFinished()
            await writer.finishWriting()
            return writer.status == .completed
        }
        writer.cancelWriting()
        if let url { try? FileManager.default.removeItem(at: url) }
        return false
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let writer, let input, writer.status == .writing else { return }
        let pts = sampleBuffer.presentationTimeStamp

        if isPaused {
            if pauseStartedAt == nil { pauseStartedAt = pts }
            return
        }
        if let pausedAt = pauseStartedAt {
            pausedTotal = CMTimeAdd(pausedTotal, CMTimeSubtract(pts, pausedAt))
            pauseStartedAt = nil
        }
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            firstSampleDate = Date()
        }
        let buffer = CMTimeCompare(pausedTotal, .zero) > 0
            ? (Self.retimed(sampleBuffer, by: pausedTotal) ?? sampleBuffer)
            : sampleBuffer
        if input.isReadyForMoreMediaData {
            input.append(buffer)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onUnexpectedStop?(error)
    }

    /// Shifts a sample buffer earlier so paused time leaves no gap in the file.
    private static func retimed(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for index in timings.indices {
            timings[index].presentationTimeStamp = CMTimeSubtract(timings[index].presentationTimeStamp, offset)
            timings[index].decodeTimeStamp = .invalid
        }
        var result: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &result
        )
        return result
    }
}
