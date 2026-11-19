import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Screen video options for meeting recordings.
struct ScreenVideoSettings: Equatable {
    var displayID: CGDirectDisplayID?
    var framesPerSecond: Int
    /// Longest side in pixels (0 = full resolution).
    var maxDimension: Int
    var hideMacPilot: Bool

    @MainActor
    static var current: ScreenVideoSettings {
        let defaults = UserDefaults.standard
        let display = UInt32(defaults.integer(forKey: PrefKey.screenDisplayID))
        return ScreenVideoSettings(
            displayID: display == 0 ? nil : display,
            framesPerSecond: max(1, min(60, defaults.integer(forKey: PrefKey.screenFPS))),
            maxDimension: defaults.integer(forKey: PrefKey.screenMaxDimension),
            hideMacPilot: defaults.bool(forKey: PrefKey.screenHideMacPilot)
        )
    }

    /// Output size for a display of `width`×`height` pixels: aspect kept, even numbers (H.264 needs them).
    static func outputSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        var w = Double(width), h = Double(height)
        if maxDimension > 0, max(w, h) > Double(maxDimension) {
            let scale = Double(maxDimension) / max(w, h)
            w *= scale
            h *= scale
        }
        return (max(2, Int(w) & ~1), max(2, Int(h) & ~1))
    }

    /// Rough H.264 bitrate for screen content (text-heavy, mostly static).
    static func bitrate(width: Int, height: Int, fps: Int) -> Int {
        let pixels = Double(width * height)
        let perPixel = fps <= 5 ? 0.12 : (fps <= 15 ? 0.08 : 0.06)
        return max(500_000, Int(pixels * Double(fps) * perPixel))
    }
}

/// Captures, with one ScreenCaptureKit stream, the audio other apps play (for example the remote side
/// of a call) to an AAC .m4a file and, optionally, the screen to an H.264 .mp4 file.
/// Requires Screen Recording permission. MacPilot's own audio is excluded.
/// Mutable state is confined to `queue`; setup and teardown happen on the caller's task.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.macpilot.system-audio")
    private var stream: SCStream?

    private final class Track {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let url: URL
        var sessionStarted = false
        var firstSampleDate: Date?

        init(writer: AVAssetWriter, input: AVAssetWriterInput, url: URL) {
            self.writer = writer
            self.input = input
            self.url = url
        }
    }

    private var audio: Track?
    private var video: Track?

    // Accessed only on `queue`.
    private var isPaused = false
    private var pauseStartedAt: CMTime?
    private var pausedTotal = CMTime.zero

    /// Called on an arbitrary queue if capture stops unexpectedly.
    var onUnexpectedStop: ((Error) -> Void)?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; returns the current permission.
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Audio only (the original behaviour).
    func start(url: URL) async throws {
        try await start(audioURL: url, videoURL: nil, video: nil)
    }

    func start(audioURL: URL?, videoURL: URL?, video settings: ScreenVideoSettings?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = settings?.displayID.flatMap { id in content.displays.first { $0.displayID == id } }
            ?? content.displays.first { $0.displayID == CGMainDisplayID() }
            ?? content.displays.first
        guard let display else { throw RecorderError.noDisplay }

        var excluded: [SCRunningApplication] = []
        if settings?.hideMacPilot == true, let ownID = Bundle.main.bundleIdentifier {
            excluded = content.applications.filter { $0.bundleIdentifier == ownID }
        }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = audioURL != nil
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        if let videoURL, let settings {
            let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }?
                .backingScaleFactor ?? 2
            let size = ScreenVideoSettings.outputSize(width: Int(Double(display.width) * scale), height: Int(Double(display.height) * scale),
                                                      maxDimension: settings.maxDimension)
            configuration.width = size.width
            configuration.height = size.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.framesPerSecond))
            configuration.showsCursor = true
            configuration.queueDepth = 6
            configuration.pixelFormat = kCVPixelFormatType_32BGRA

            let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: ScreenVideoSettings.bitrate(width: size.width, height: size.height, fps: settings.framesPerSecond),
                    AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: settings.framesPerSecond * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw AVError(.unknown) }
            writer.add(input)
            video = Track(writer: writer, input: input, url: videoURL)
        } else {
            // Audio only: keep the (required) video side as small and slow as possible; frames are discarded.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.showsCursor = false
        }

        if let audioURL {
            let writer = try AVAssetWriter(outputURL: audioURL, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 96_000
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw AVError(.unknown) }
            writer.add(input)
            audio = Track(writer: writer, input: input, url: audioURL)
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        if audio != nil { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if video != nil { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) }

        for track in [audio, video].compactMap({ $0 }) {
            guard track.writer.startWriting() else { throw track.writer.error ?? AVError(.unknown) }
        }
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            audio?.writer.cancelWriting()
            video?.writer.cancelWriting()
            self.stream = nil
            throw error
        }
    }

    func pause() { queue.async { self.isPaused = true } }
    func resume() { queue.async { self.isPaused = false } }

    /// When the first audio sample was written, if any.
    func startDate() async -> Date? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.audio?.firstSampleDate) }
        }
    }

    /// When the first screen frame was written, if any.
    func videoStartDate() async -> Date? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.video?.firstSampleDate) }
        }
    }

    /// Stops capture and finishes the audio file. Returns false when no audio was captured (the file is removed).
    func stop() async -> Bool {
        await stopAll().audio
    }

    /// Stops capture and finishes both files; a file without any samples is removed.
    func stopAll() async -> (audio: Bool, video: Bool) {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        // Let queued samples finish before closing the files.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        let audioOK = await finish(audio)
        let videoOK = await finish(video)
        return (audioOK, videoOK)
    }

    private func finish(_ track: Track?) async -> Bool {
        guard let track else { return false }
        if track.sessionStarted {
            track.input.markAsFinished()
            await track.writer.finishWriting()
            return track.writer.status == .completed
        }
        track.writer.cancelWriting()
        try? FileManager.default.removeItem(at: track.url)
        return false
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let track: Track?
        switch type {
        case .audio: track = audio
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            track = video
        default: track = nil
        }
        guard let track, track.writer.status == .writing else { return }
        let pts = sampleBuffer.presentationTimeStamp

        if isPaused {
            if pauseStartedAt == nil { pauseStartedAt = pts }
            return
        }
        if let pausedAt = pauseStartedAt {
            pausedTotal = CMTimeAdd(pausedTotal, CMTimeSubtract(pts, pausedAt))
            pauseStartedAt = nil
        }
        let adjusted = CMTimeSubtract(pts, pausedTotal)
        if !track.sessionStarted {
            track.writer.startSession(atSourceTime: adjusted)
            track.sessionStarted = true
            track.firstSampleDate = Date()
        }
        let buffer = CMTimeCompare(pausedTotal, .zero) > 0
            ? (Self.retimed(sampleBuffer, by: pausedTotal) ?? sampleBuffer)
            : sampleBuffer
        if track.input.isReadyForMoreMediaData {
            track.input.append(buffer)
        }
    }

    /// ScreenCaptureKit also delivers idle/blank frames; only complete frames carry new pixels.
    private static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
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
