import AVFoundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

enum RecorderError: LocalizedError {
    case microphoneDenied
    case noMicrophone
    case cannotAddInput
    case noDisplay
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "MacPilot does not have microphone access. Allow it in System Settings → Privacy & Security → Microphone."
        case .noMicrophone:
            return "No microphone was found."
        case .cannotAddInput:
            return "The selected microphone could not be used. Pick another one in Settings → Recording."
        case .noDisplay:
            return "No display was found for capturing system audio."
        case .alreadyRecording:
            return "A recording is already in progress."
        }
    }
}

/// Records the microphone to an AAC .m4a file with pause/resume and a level meter.
/// Shared state is guarded by `lock`.
final class MicRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    private let dataOutput = AVCaptureAudioDataOutput()
    private let dataQueue = DispatchQueue(label: "com.macpilot.mic-data")
    /// Raw microphone audio for live transcription, called on a background queue. Set before `start`.
    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    private var _startedAt: Date?

    /// When the file actually started receiving audio (used to align the system audio track).
    var startedAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _startedAt
    }

    static func availableDevices() -> [AudioInputDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(deviceID: String?, url: URL) throws {
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw RecorderError.noMicrophone }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecorderError.cannotAddInput
        }
        session.addInput(input)
        if session.canAddOutput(output) { session.addOutput(output) }
        if onAudio != nil, session.canAddOutput(dataOutput) {
            session.addOutput(dataOutput)
            dataOutput.setSampleBufferDelegate(self, queue: dataQueue)
        }
        session.commitConfiguration()

        output.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        session.startRunning()
        output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
    }

    func pause() { output.pauseRecording() }
    func resume() { output.resumeRecording() }

    /// Average input level from 0 (silence) to 1.
    var level: Float {
        let channels = output.connections.first?.audioChannels ?? []
        guard !channels.isEmpty else { return 0 }
        let decibels = channels.map(\.averagePowerLevel).reduce(0, +) / Float(channels.count)
        // Map -60 dB…0 dB to 0…1.
        return max(0, min(1, (decibels + 60) / 60))
    }

    func stop() async {
        guard output.isRecording else {
            session.stopRunning()
            return
        }
        await withCheckedContinuation { continuation in
            lock.lock()
            finishContinuation = continuation
            lock.unlock()
            output.stopRecording()
        }
        session.stopRunning()
    }

    // MARK: AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onAudio, let buffer = sampleBuffer.pcmBuffer() else { return }
        onAudio(buffer)
    }

    // MARK: AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        lock.lock()
        _startedAt = Date()
        lock.unlock()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        lock.lock()
        let continuation = finishContinuation
        finishContinuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
