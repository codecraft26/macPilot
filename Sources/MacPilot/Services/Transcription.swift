import AVFoundation
import Foundation

enum TranscriptionError: LocalizedError {
    case noAudio
    case fileTooLarge(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio:
            return "This recording has no audio file left to transcribe."
        case .fileTooLarge(let name):
            return "\(name) is larger than the 25 MB OpenAI upload limit and could not be split. Convert it to M4A, MP3 or WAV and import it again."
        case .exportFailed(let reason):
            return "Could not prepare the audio for upload: \(reason)"
        }
    }
}

/// Speech-to-text for recordings. The provider is chosen in Settings → Routing, independent of chat.
enum TranscriptionService {
    /// Length of each uploaded piece. Short enough to stay well under the 25 MB limit and to give
    /// useful timestamps when the model does not return segments.
    static let chunkSeconds: Double = 120
    static let uploadLimit = 25 * 1024 * 1024

    static func transcribe(_ recording: RecordingSnapshot, liveMicrophone: [TranscriptSegment] = []) async throws -> [TranscriptSegment] {
        let provider = Prefs.transcriptionProvider
        var tracks: [[TranscriptSegment]] = []
        if provider == .amazonTranscribe, !liveMicrophone.isEmpty {
            tracks.append(liveMicrophone)
        } else if let mic = recording.micURL {
            tracks.append(try await transcribe(mic, speaker: recording.micSpeaker, offset: 0, provider: provider))
        }
        if let system = recording.systemURL {
            tracks.append(try await transcribe(system, speaker: "Others", offset: recording.systemOffset, provider: provider))
        }
        guard !tracks.isEmpty else { throw TranscriptionError.noAudio }
        return TranscriptMerger.merge(tracks)
    }

    /// Transcribes one audio file with the given provider (used for recordings and dictation).
    static func transcribe(
        _ url: URL, speaker: String, offset: Double, provider: TranscriptionProviderID
    ) async throws -> [TranscriptSegment] {
        switch provider {
        case .localWhisper:
            return try await LocalWhisper.transcribe(url, speaker: speaker, offset: offset)
        case .amazonTranscribe:
            if TranscribeSettings.bucket.isEmpty {
                return try await TranscribeStream.transcribe(fileURL: url, track: speaker, offset: offset)
            }
            return try await withCompatibleAudio(url, needsConversion: TranscribeAPI.mediaFormat(for: url) == nil) {
                try await TranscribeBatch.transcribe(fileURL: $0, track: speaker, offset: offset)
            }
        case .bedrock:
            return try await withCompatibleAudio(url, needsConversion: !BedrockTranscription.supports(url)) {
                try await BedrockTranscription.transcribe(fileURL: $0, track: speaker, offset: offset)
            }
        case .openAI:
            return try await transcribeFile(url, speaker: speaker, model: Prefs.transcriptionModel, offset: offset)
        }
    }

    private static func withCompatibleAudio(
        _ source: URL, needsConversion: Bool, transcribe: (URL) async throws -> [TranscriptSegment]
    ) async throws -> [TranscriptSegment] {
        guard needsConversion else { return try await transcribe(source) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacPilot-Audio-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let wave = temporary.appendingPathComponent("audio.wav")
        guard await AudioTools.convertToWave(source, output: wave) else { throw TranscribeError.unreadableAudio }
        return try await transcribe(wave)
    }

    static func transcribeFile(_ url: URL, speaker: String, model: String, offset: Double) async throws -> [TranscriptSegment] {
        let duration = await AudioTools.duration(of: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        // Formats AVFoundation cannot read (e.g. OGG) are uploaded as they are.
        guard let duration else {
            guard size <= uploadLimit else { throw TranscriptionError.fileTooLarge(url.lastPathComponent) }
            let json = try await OpenAITranscriber.transcribe(fileURL: url, model: model)
            return TranscriptParsing.segments(from: json, offset: offset, duration: nil, speaker: speaker)
        }

        if duration <= chunkSeconds && size <= uploadLimit {
            let json = try await OpenAITranscriber.transcribe(fileURL: url, model: model)
            return TranscriptParsing.segments(from: json, offset: offset, duration: duration, speaker: speaker)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var result: [TranscriptSegment] = []
        var start: Double = 0
        var index = 0
        while start < duration {
            try Task.checkCancellation()
            let length = min(chunkSeconds, duration - start)
            let chunkURL = tempDir.appendingPathComponent("chunk-\(index).m4a")
            try await AudioTools.export(url, to: chunkURL, start: start, duration: length)
            let json = try await OpenAITranscriber.transcribe(fileURL: chunkURL, model: model)
            result += TranscriptParsing.segments(from: json, offset: offset + start, duration: length, speaker: speaker)
            start += length
            index += 1
        }
        return result
    }
}

/// Values copied off the SwiftData model so transcription can run without touching it.
struct RecordingSnapshot {
    var micURL: URL?
    var systemURL: URL?
    var systemOffset: Double
    var micSpeaker: String

    @MainActor
    init(_ recording: Recording) {
        let existing = Set(recording.audioURLs)
        micURL = recording.micURL.flatMap { existing.contains($0) ? $0 : nil }
        systemURL = recording.systemURL.flatMap { existing.contains($0) ? $0 : nil }
        systemOffset = recording.systemAudioOffset
        micSpeaker = recording.speakerLabelForMic
    }
}

enum OpenAITranscriber {
    static func transcribe(fileURL: URL, model: String) async throws -> [String: Any] {
        guard Prefs.isEnabled(.openAI) else { throw AIError.providerDisabled(.openAI) }
        guard let key = KeychainStore.read(account: AIProviderID.openAI.rawValue), !key.isEmpty else {
            throw AIError.missingKey(.openAI)
        }
        let boundary = "MacPilot-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var fields: [(String, String)] = [("model", model)]
        if let hint = DictationPrompt.transcriptionHint(vocabulary: Prefs.dictationVocabulary) {
            fields.append(("prompt", hint)) // spells names and terms from Settings → Dictation correctly
        }
        if model.hasPrefix("whisper") {
            fields.append(("response_format", "verbose_json"))
            fields.append(("timestamp_granularities[]", "segment"))
        } else {
            fields.append(("response_format", "json"))
        }
        let audio = try Data(contentsOf: fileURL)
        request.httpBody = Multipart.body(
            boundary: boundary,
            fields: fields,
            file: (name: "file", fileName: fileURL.lastPathComponent, mimeType: Multipart.mimeType(for: fileURL), data: audio)
        )

        let (data, response) = try await HTTPSupport.session.data(for: request)
        try HTTPSupport.ensureOK(response, data: data, provider: .openAI)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIError.invalidResponse
        }
        return json
    }
}

enum Multipart {
    static func body(boundary: String, fields: [(String, String)], file: (name: String, fileName: String, mimeType: String, data: Data)) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.fileName)\"\r\n")
        append("Content-Type: \(file.mimeType)\r\n\r\n")
        body.append(file.data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "aac": return "audio/aac"
        case "mp4": return "audio/mp4"
        case "aiff", "aif": return "audio/aiff"
        default: return "audio/m4a"
        }
    }
}

/// Turns a transcription response into timed segments.
enum TranscriptParsing {
    static func segments(from json: [String: Any], offset: Double, duration: Double?, speaker: String) -> [TranscriptSegment] {
        if let raw = json["segments"] as? [[String: Any]], !raw.isEmpty {
            let parsed: [TranscriptSegment] = raw.compactMap { item in
                let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let start = number(item["start"]) ?? 0
                let end = number(item["end"]) ?? start
                let label = (item["speaker"] as? String).map { "Speaker \($0)" } ?? speaker
                return TranscriptSegment(start: offset + start, end: offset + end, speaker: label, text: text)
            }
            if !parsed.isEmpty { return parsed }
        }
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return spread(text: text, offset: offset, duration: duration ?? number(json["duration"]) ?? 0, speaker: speaker)
    }

    /// Without segment timestamps, split into sentences and spread them over the chunk by length.
    static func spread(text: String, offset: Double, duration: Double, speaker: String) -> [TranscriptSegment] {
        let sentences = sentences(in: text)
        let totalLength = Double(sentences.reduce(0) { $0 + $1.count })
        guard totalLength > 0 else { return [] }
        var cursor = offset
        return sentences.map { sentence in
            let length = duration * Double(sentence.count) / totalLength
            defer { cursor += length }
            return TranscriptSegment(start: cursor, end: cursor + length, speaker: speaker, text: sentence)
        }
    }

    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                result.append(sentence)
            }
        }
        return result.isEmpty ? [text] : result
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

enum TranscriptMerger {
    /// Interleaves tracks by start time (stable for equal starts).
    static func merge(_ tracks: [[TranscriptSegment]]) -> [TranscriptSegment] {
        tracks.enumerated()
            .flatMap { trackIndex, segments in segments.enumerated().map { (trackIndex, $0, $1) } }
            .sorted { lhs, rhs in
                if lhs.2.start != rhs.2.start { return lhs.2.start < rhs.2.start }
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1 < rhs.1
            }
            .map(\.2)
    }
}

extension AudioTools {
    static func convertToWave(_ source: URL, output: URL) async -> Bool {
        await Shell.run("/usr/bin/afconvert", [
            "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", "--mix", source.path, output.path
        ], timeout: 600).ok
    }

    /// Writes `duration` seconds of `url` starting at `start` to an .m4a file.
    static func export(_ url: URL, to output: URL, start: Double, duration: Double) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.exportFailed("unsupported audio format")
        }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        if #available(macOS 15, *) {
            do {
                try await session.export(to: output, as: .m4a)
            } catch {
                throw TranscriptionError.exportFailed(error.localizedDescription)
            }
        } else {
            session.outputURL = output
            session.outputFileType = .m4a
            await session.export()
            guard session.status == .completed else {
                throw TranscriptionError.exportFailed(session.error?.localizedDescription ?? "unknown error")
            }
        }
    }
}
