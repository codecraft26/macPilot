import AVFoundation
import CryptoKit
import Foundation

// MARK: - Settings and credentials

enum TranscribeSettings {
    static let languages: [(code: String, label: String)] = [
        ("auto", "Detect automatically"), ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("en-IN", "English (India)"),
        ("hi-IN", "Hindi"), ("es-US", "Spanish (US)"), ("es-ES", "Spanish (Spain)"), ("fr-FR", "French"), ("de-DE", "German"),
        ("it-IT", "Italian"), ("pt-BR", "Portuguese (Brazil)"), ("ja-JP", "Japanese"), ("ko-KR", "Korean"), ("zh-CN", "Chinese (Mandarin)")
    ]
    /// Candidates for automatic language identification in streaming (it needs an explicit list).
    static let streamingLanguageOptions = ["en-US", "en-GB", "en-IN", "hi-IN", "es-US", "fr-FR", "de-DE"]

    private static var defaults: UserDefaults { .standard }

    static var region: String {
        let value = (defaults.string(forKey: PrefKey.transcribeRegion) ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? BedrockConfig.region : value
    }
    static var bucket: String { (defaults.string(forKey: PrefKey.transcribeBucket) ?? "").trimmingCharacters(in: .whitespaces) }
    static var keyPrefix: String {
        let value = (defaults.string(forKey: PrefKey.transcribePrefix) ?? "macpilot/").trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "" }
        return value.hasSuffix("/") ? value : value + "/"
    }
    static var language: String { defaults.string(forKey: PrefKey.transcribeLanguage) ?? "auto" }
    static var identifySpeakers: Bool { defaults.bool(forKey: PrefKey.transcribeIdentifySpeakers) }
    static var maxSpeakers: Int { min(10, max(2, defaults.integer(forKey: PrefKey.transcribeMaxSpeakers))) }
    static var deleteAfter: Bool { defaults.bool(forKey: PrefKey.transcribeDeleteAfter) }
    static var liveEnabled: Bool { defaults.bool(forKey: PrefKey.transcribeLive) }
    static var useLiveTranscript: Bool { defaults.bool(forKey: PrefKey.transcribeUseLive) }

    /// Transcribe needs signed requests, so a Bedrock API key (bearer token) is not enough.
    static var hasAccessKeys: Bool {
        KeychainStore.exists(account: BedrockConfig.Account.accessKeyID) && KeychainStore.exists(account: BedrockConfig.Account.secretAccessKey)
    }

    static func signer(service: String, region: String? = nil) throws -> AWSSigV4Signer {
        guard let keyID = KeychainStore.read(account: BedrockConfig.Account.accessKeyID), !keyID.isEmpty,
              let secret = KeychainStore.read(account: BedrockConfig.Account.secretAccessKey), !secret.isEmpty else {
            throw TranscribeError.missingAccessKeys
        }
        return AWSSigV4Signer(accessKeyID: keyID, secretAccessKey: secret,
                              sessionToken: KeychainStore.read(account: BedrockConfig.Account.sessionToken),
                              region: region ?? self.region, service: service)
    }
}

enum TranscribeError: LocalizedError {
    case missingAccessKeys
    case aws(service: String, status: Int, message: String)
    case jobFailed(String)
    case timedOut
    case unreadableAudio
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .missingAccessKeys:
            return "Amazon Transcribe needs an AWS access key ID and secret. Add them under Settings → Providers → Claude via Amazon Bedrock (a Bedrock API key alone can't sign Transcribe or S3 requests)."
        case let .aws(service, status, message):
            var text = "\(service) returned \(status): \(Redactor.redact(message))"
            if status == 403 || message.localizedCaseInsensitiveContains("AccessDenied") {
                text += " — check the IAM permissions listed in Settings → Routing → Audio transcription."
            }
            return text
        case .jobFailed(let reason): return "Amazon Transcribe could not transcribe the audio: \(Redactor.redact(reason))"
        case .timedOut: return "Amazon Transcribe took too long. Try again later."
        case .unreadableAudio: return "This audio format can't be streamed. Set an S3 bucket in Settings → Routing to transcribe it with a batch job."
        case .stream(let message): return "Amazon Transcribe streaming: \(Redactor.redact(message))"
        }
    }
}

// MARK: - Requests

enum AWSHTTP {
    static func errorMessage(_ data: Data) -> String {
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let type = (json["__type"] as? String)?.split(separator: "#").last.map(String.init)
            let message = (json["message"] ?? json["Message"]) as? String
            return [type, message].compactMap { $0 }.joined(separator: ": ")
        }
        // S3 returns XML.
        let text = String(decoding: data.prefix(2000), as: UTF8.self)
        if let start = text.range(of: "<Message>"), let end = text.range(of: "</Message>"), start.upperBound <= end.lowerBound {
            let code = text.range(of: "<Code>").flatMap { s in text.range(of: "</Code>").map { String(text[s.upperBound..<$0.lowerBound]) } }
            return [code, String(text[start.upperBound..<end.lowerBound])].compactMap { $0 }.joined(separator: ": ")
        }
        return text.isEmpty ? "Unknown error" : text
    }

    static func send(_ request: URLRequest, service: String) async throws -> Data {
        let (data, response) = try await HTTPSupport.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw TranscribeError.aws(service: service, status: status, message: errorMessage(data)) }
        return data
    }
}

enum S3Client {
    /// Virtual-hosted style URL; each key segment is percent-encoded once (S3 does not double-encode).
    static func objectURL(bucket: String, region: String, key: String) -> URL {
        let path = key.split(separator: "/", omittingEmptySubsequences: false)
            .map { AWSSigV4Signer.encode(String($0)) }
            .joined(separator: "/")
        return URL(string: "https://\(bucket).s3.\(region).amazonaws.com/\(path)")!
    }

    static func put(fileURL: URL, bucket: String, key: String, region: String) async throws {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let url = objectURL(bucket: bucket, region: region, key: key)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 1800
        let headers = [
            "content-type": Multipart.mimeType(for: fileURL),
            "x-amz-content-sha256": AWSSigV4Signer.hex(SHA256Digest.of(data))
        ]
        let signer = try TranscribeSettings.signer(service: "s3", region: region)
        for (name, value) in headers.merging(signer.signedHeaders(method: "PUT", url: url, headers: headers, body: data), uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = data
        _ = try await AWSHTTP.send(request, service: "Amazon S3")
    }

    static func delete(bucket: String, key: String, region: String) async {
        let url = objectURL(bucket: bucket, region: region, key: key)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let headers = ["x-amz-content-sha256": AWSSigV4Signer.hex(SHA256Digest.of(Data()))]
        guard let signer = try? TranscribeSettings.signer(service: "s3", region: region) else { return }
        for (name, value) in headers.merging(signer.signedHeaders(method: "DELETE", url: url, headers: headers, body: Data()), uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        _ = try? await AWSHTTP.send(request, service: "Amazon S3")
    }
}

enum SHA256Digest {
    static func of(_ data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }
}

/// The Amazon Transcribe JSON API (batch jobs).
enum TranscribeAPI {
    static func call(_ action: String, _ body: [String: Any], region: String) async throws -> [String: Any] {
        let url = URL(string: "https://transcribe.\(region).amazonaws.com/")!
        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        let headers = ["content-type": "application/x-amz-json-1.1", "x-amz-target": "Transcribe.\(action)"]
        let signer = try TranscribeSettings.signer(service: "transcribe", region: region)
        for (name, value) in headers.merging(signer.signedHeaders(method: "POST", url: url, headers: headers, body: data), uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = data
        let response = try await AWSHTTP.send(request, service: "Amazon Transcribe")
        return (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] ?? [:]
    }

    static func mediaFormat(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "mp3": return "mp3"
        case "mp4", "m4a", "aac": return "mp4"
        case "wav": return "wav"
        case "flac": return "flac"
        case "ogg": return "ogg"
        case "webm": return "webm"
        case "amr": return "amr"
        default: return nil
        }
    }
}

// MARK: - Turning results into segments

enum TranscribeParsing {
    /// Speaker label for a Transcribe speaker ("spk_0" or "0") on a given track.
    static func speakerName(_ raw: String?, track: String, multipleSpeakers: Bool) -> String {
        guard let raw, !raw.isEmpty else { return track }
        let digits = raw.filter(\.isNumber)
        let number = (Int(digits) ?? 0) + 1
        switch track {
        case "Me": return (!multipleSpeakers || number == 1) ? "Me" : "Room speaker \(number)"
        default: return "Speaker \(number)"
        }
    }

    /// Batch job output (`results.audio_segments`, or items + speaker_labels, or plain transcript).
    static func batchSegments(_ json: [String: Any], offset: Double, track: String, duration: Double?) -> [TranscriptSegment] {
        guard let results = json["results"] as? [String: Any] else { return [] }
        let speakerSet = Set(((results["speaker_labels"] as? [String: Any])?["segments"] as? [[String: Any]] ?? []).compactMap { $0["speaker_label"] as? String })
        let multiple = speakerSet.count > 1

        if let segments = results["audio_segments"] as? [[String: Any]], !segments.isEmpty {
            return segments.compactMap { segment in
                let text = (segment["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let start = number(segment["start_time"]) ?? 0
                let end = number(segment["end_time"]) ?? start
                let speaker = speakerName(segment["speaker_label"] as? String, track: track, multipleSpeakers: multiple || hasManySpeakers(segments))
                return TranscriptSegment(start: offset + start, end: offset + end, speaker: speaker, text: text)
            }
        }

        if let items = results["items"] as? [[String: Any]], !items.isEmpty {
            var speakerAt: [String: String] = [:]
            for segment in (results["speaker_labels"] as? [String: Any])?["segments"] as? [[String: Any]] ?? [] {
                for item in segment["items"] as? [[String: Any]] ?? [] {
                    if let start = item["start_time"] as? String, let label = item["speaker_label"] as? String { speakerAt[start] = label }
                }
            }
            let words: [Word] = items.compactMap { item in
                let content = ((item["alternatives"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
                let isPunctuation = item["type"] as? String == "punctuation"
                let startString = item["start_time"] as? String
                return Word(text: content, start: number(item["start_time"]), end: number(item["end_time"]),
                            speaker: (item["speaker_label"] as? String) ?? startString.flatMap { speakerAt[$0] }, isPunctuation: isPunctuation)
            }
            return group(words, offset: offset) { speakerName($0, track: track, multipleSpeakers: multiple) }
        }

        let text = ((results["transcripts"] as? [[String: Any]])?.first?["transcript"] as? String) ?? ""
        return TranscriptParsing.spread(text: text, offset: offset, duration: duration ?? 0, speaker: track == "Me" ? "Me" : track)
    }

    /// Final streaming results → segments (one per result, split where the speaker changes).
    static func streamingSegments(_ results: [[String: Any]], offset: Double, track: String) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        for result in results where result["IsPartial"] as? Bool != true {
            guard let alternative = (result["Alternatives"] as? [[String: Any]])?.first else { continue }
            let items = alternative["Items"] as? [[String: Any]] ?? []
            let speakers = Set(items.compactMap { $0["Speaker"] as? String })
            if items.isEmpty || speakers.isEmpty {
                let text = (alternative["Transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                output.append(TranscriptSegment(start: offset + (number(result["StartTime"]) ?? 0), end: offset + (number(result["EndTime"]) ?? 0),
                                                speaker: track == "Me" ? "Me" : (track == "Others" ? "Others" : track), text: text))
                continue
            }
            let words = items.map { item in
                Word(text: item["Content"] as? String ?? "", start: number(item["StartTime"]), end: number(item["EndTime"]),
                     speaker: item["Speaker"] as? String, isPunctuation: item["Type"] as? String == "punctuation")
            }
            output += group(words, offset: offset) { speakerName($0, track: track, multipleSpeakers: speakers.count > 1) }
        }
        return output
    }

    struct Word {
        var text: String
        var start: Double?
        var end: Double?
        var speaker: String?
        var isPunctuation: Bool
    }

    /// Joins words into segments, breaking on speaker changes and after sentence-ending punctuation past ~20 words.
    static func group(_ words: [Word], offset: Double, name: (String?) -> String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var text = ""
        var start: Double?
        var end: Double = 0
        var speaker: String?
        var count = 0

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, let start {
                segments.append(TranscriptSegment(start: offset + start, end: offset + max(end, start), speaker: name(speaker), text: trimmed))
            }
            text = ""
            start = nil
            count = 0
        }

        for word in words {
            if word.isPunctuation {
                text += word.text
                if [".", "?", "!"].contains(word.text) && count >= 20 { flush() }
                continue
            }
            if let wordSpeaker = word.speaker, let current = speaker, wordSpeaker != current, !text.isEmpty { flush() }
            if word.speaker != nil { speaker = word.speaker }
            if start == nil { start = word.start }
            if let wordEnd = word.end { end = wordEnd }
            text += (text.isEmpty ? "" : " ") + word.text
            count += 1
        }
        flush()
        return segments
    }

    private static func hasManySpeakers(_ segments: [[String: Any]]) -> Bool {
        Set(segments.compactMap { $0["speaker_label"] as? String }).count > 1
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

// MARK: - Batch transcription (S3 + StartTranscriptionJob)

enum TranscribeBatch {
    static func s3Key(prefix: String, fileURL: URL, id: UUID = UUID()) -> String {
        "\(prefix)\(id.uuidString.lowercased())/\(fileURL.lastPathComponent)"
    }

    static func transcribe(fileURL: URL, track: String, offset: Double) async throws -> [TranscriptSegment] {
        let region = TranscribeSettings.region
        let bucket = TranscribeSettings.bucket
        let key = s3Key(prefix: TranscribeSettings.keyPrefix, fileURL: fileURL)
        let jobName = "macpilot-\(UUID().uuidString.lowercased())"
        guard let format = TranscribeAPI.mediaFormat(for: fileURL) else { throw TranscribeError.unreadableAudio }

        try await S3Client.put(fileURL: fileURL, bucket: bucket, key: key, region: region)
        var jobStarted = false
        defer {
            if TranscribeSettings.deleteAfter {
                Task {
                    await S3Client.delete(bucket: bucket, key: key, region: region)
                    if jobStarted { _ = try? await TranscribeAPI.call("DeleteTranscriptionJob", ["TranscriptionJobName": jobName], region: region) }
                }
            }
        }

        var body: [String: Any] = [
            "TranscriptionJobName": jobName,
            "Media": ["MediaFileUri": "s3://\(bucket)/\(key)"],
            "MediaFormat": format
        ]
        if TranscribeSettings.language == "auto" {
            body["IdentifyLanguage"] = true
        } else {
            body["LanguageCode"] = TranscribeSettings.language
        }
        if TranscribeSettings.identifySpeakers {
            body["Settings"] = ["ShowSpeakerLabels": true, "MaxSpeakerLabels": TranscribeSettings.maxSpeakers]
        }
        _ = try await TranscribeAPI.call("StartTranscriptionJob", body, region: region)
        jobStarted = true

        // Poll with backoff: 2 s, growing to 15 s, for up to two hours.
        var delay: Double = 2
        let deadline = Date().addingTimeInterval(2 * 3600)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(delay))
            delay = min(15, delay * 1.5)
            let response = try await TranscribeAPI.call("GetTranscriptionJob", ["TranscriptionJobName": jobName], region: region)
            let job = response["TranscriptionJob"] as? [String: Any] ?? [:]
            switch job["TranscriptionJobStatus"] as? String {
            case "COMPLETED":
                guard let uri = (job["Transcript"] as? [String: Any])?["TranscriptFileUri"] as? String, let url = URL(string: uri) else {
                    throw TranscribeError.jobFailed("no transcript file")
                }
                let (data, _) = try await HTTPSupport.session.data(from: url) // pre-signed URL; never logged
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                return TranscribeParsing.batchSegments(json, offset: offset, track: track, duration: await AudioTools.duration(of: fileURL))
            case "FAILED":
                throw TranscribeError.jobFailed(job["FailureReason"] as? String ?? "unknown reason")
            default:
                continue
            }
        }
        throw TranscribeError.timedOut
    }
}

// MARK: - Streaming (WebSocket)

/// One Amazon Transcribe streaming session: feed 16 kHz mono Int16 PCM, receive results.
final class TranscribeStream: @unchecked Sendable {
    struct Update {
        var partial: String?
        var finals: [[String: Any]]
    }

    private let onUpdate: @Sendable (Update) -> Void
    private var audio: AsyncStream<Data>.Continuation?
    private var task: Task<Void, Error>?

    init(onUpdate: @escaping @Sendable (Update) -> Void) {
        self.onUpdate = onUpdate
    }

    static func url(region: String, language: String, speakers: Bool) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "transcribestreaming.\(region).amazonaws.com"
        components.port = 8443
        components.path = "/stream-transcription-websocket"
        var items = [URLQueryItem(name: "media-encoding", value: "pcm"), URLQueryItem(name: "sample-rate", value: "16000")]
        if language == "auto" {
            items.append(URLQueryItem(name: "identify-language", value: "true"))
            items.append(URLQueryItem(name: "language-options", value: TranscribeSettings.streamingLanguageOptions.joined(separator: ",")))
        } else {
            items.append(URLQueryItem(name: "language-code", value: language))
        }
        if speakers { items.append(URLQueryItem(name: "show-speaker-label", value: "true")) }
        components.queryItems = items
        return components.url!
    }

    /// Starts the WebSocket. Completes (or throws) when the service closes the stream after `finish()`.
    func start() throws {
        let signer = try TranscribeSettings.signer(service: "transcribe")
        let url = signer.presignedURL(Self.url(region: TranscribeSettings.region, language: TranscribeSettings.language,
                                               speakers: TranscribeSettings.identifySpeakers), expires: 300)
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(400))
        audio = continuation
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 4 * 1024 * 1024
        socket.resume()
        let onUpdate = onUpdate
        task = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await chunk in stream {
                        try await socket.send(.data(EventStream.audioEvent(chunk)))
                    }
                    try await socket.send(.data(EventStream.audioEvent(Data()))) // end of audio
                }
                group.addTask {
                    var buffer = Data()
                    while true {
                        let message: URLSessionWebSocketTask.Message
                        do {
                            message = try await socket.receive()
                        } catch {
                            if socket.closeCode == .normalClosure || buffer.isEmpty && socket.state != .running { return }
                            throw TranscribeError.stream(error.localizedDescription)
                        }
                        guard case .data(let data) = message else { continue }
                        buffer.append(data)
                        for event in try EventStream.decode(&buffer) {
                            let json = (try? JSONSerialization.jsonObject(with: event.payload)) as? [String: Any] ?? [:]
                            if event.headers[":message-type"] == "exception" {
                                throw TranscribeError.stream((json["Message"] ?? json["message"]) as? String ?? event.headers[":exception-type"] ?? "error")
                            }
                            guard event.headers[":event-type"] == "TranscriptEvent",
                                  let results = (json["Transcript"] as? [String: Any])?["Results"] as? [[String: Any]] else { continue }
                            let partial = results.first { $0["IsPartial"] as? Bool == true }
                                .flatMap { (($0["Alternatives"] as? [[String: Any]])?.first?["Transcript"] as? String) }
                            onUpdate(Update(partial: partial, finals: results.filter { $0["IsPartial"] as? Bool != true }))
                        }
                    }
                }
                try await group.waitForAll()
            }
            socket.cancel(with: .normalClosure, reason: nil)
        }
    }

    func send(_ pcm: Data) { audio?.yield(pcm) }

    /// Ends the audio and waits for the remaining results.
    func finish() async throws {
        audio?.finish()
        audio = nil
        try await task?.value
    }

    func cancel() {
        audio?.finish()
        task?.cancel()
    }

    /// Streams a whole file (no S3 bucket needed), paced at about four times real time.
    static func transcribe(fileURL: URL, track: String, offset: Double) async throws -> [TranscriptSegment] {
        let collector = ResultCollector()
        let stream = TranscribeStream { update in collector.add(update.finals) }
        try stream.start()
        do {
            try PCM16.readFile(fileURL) { chunk in
                stream.send(chunk)
                Thread.sleep(forTimeInterval: 0.025) // 100 ms of audio per 25 ms
            }
        } catch {
            stream.cancel()
            throw error
        }
        try await stream.finish()
        return TranscribeParsing.streamingSegments(collector.results, offset: offset, track: track)
    }
}

final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: Any]] = []
    func add(_ results: [[String: Any]]) { lock.lock(); stored += results; lock.unlock() }
    var results: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Converts audio to 16 kHz mono signed 16-bit little-endian PCM.
final class PCM16: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * 2)
    }

    /// Reads a whole file and delivers ~100 ms chunks.
    static func readFile(_ url: URL, chunk: (Data) -> Void) throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw TranscribeError.unreadableAudio }
        let converter = PCM16()
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw TranscribeError.unreadableAudio }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            if let data = converter.convert(buffer) { chunk(data) }
        }
    }
}

extension CMSampleBuffer {
    /// Copies LPCM audio from a capture sample buffer into an AVAudioPCMBuffer.
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let description = formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
