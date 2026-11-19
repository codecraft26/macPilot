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
    static let streamingLanguageOptions = ["en-US", "hi-IN", "es-US", "fr-FR", "de-DE", "ja-JP"]

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
    static var dataProfile: String { (defaults.string(forKey: PrefKey.bedrockDataProfile) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var dataProject: String { (defaults.string(forKey: PrefKey.bedrockDataProject) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    static func validate(region: String, bucket: String = "") throws {
        guard region.range(of: #"^[a-z]{2}(?:-[a-z0-9]+)+-[0-9]+$"#, options: .regularExpression) != nil else {
            throw TranscribeError.configuration("Enter a valid AWS region in Settings → Routing.")
        }
        guard bucket.isEmpty || bucket.range(of: #"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"#, options: .regularExpression) != nil else {
            throw TranscribeError.configuration("Enter the S3 bucket name in Settings → Routing.")
        }
    }

    /// Transcribe needs signed requests, so a Bedrock API key (bearer token) is not enough.
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
    case configuration(String)
    case aws(service: String, status: Int, message: String)
    case jobFailed(String)
    case timedOut
    case unreadableAudio
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .missingAccessKeys:
            return "Save an AWS access key ID and secret under Settings → Providers → Claude via Amazon Bedrock. AWS transcription uses Signature V4."
        case .configuration(let message): return message
        case let .aws(service, status, message):
            var text = "\(service) returned \(status): \(Redactor.redact(message))"
            if status == 403 || message.localizedCaseInsensitiveContains("AccessDenied") {
                text += " — check the IAM permissions listed in Settings → Routing → Audio transcription."
            }
            return text
        case .jobFailed(let reason): return Redactor.redact(reason)
        case .timedOut: return "The AWS transcription job timed out."
        case .unreadableAudio: return "This audio format could not be read. Try importing the audio as M4A, MP3, or WAV."
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

    static func jsonCall(
        url: URL, target: String, body: [String: Any], signer: AWSSigV4Signer, service: String
    ) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        let headers = ["content-type": "application/x-amz-json-1.1", "x-amz-target": target]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        for (name, value) in headers.merging(signer.signedHeaders(method: "POST", url: url, headers: headers, body: data), uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let response = try await send(request, service: service)
        return try jsonObject(response, service: service)
    }

    static func jsonObject(_ data: Data, service: String) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TranscribeError.configuration("\(service) returned an unreadable response.")
        }
        return object
    }
}

enum S3Client {
    /// Path-style addressing also supports bucket names containing dots over TLS.
    static func objectURL(bucket: String, region: String, key: String) -> URL {
        let path = key.split(separator: "/", omittingEmptySubsequences: false)
            .map { AWSSigV4Signer.encode(String($0)) }
            .joined(separator: "/")
        return URL(string: "https://s3.\(region).amazonaws.com/\(bucket)/\(path)")!
    }

    static func put(fileURL: URL, bucket: String, key: String, region: String) async throws {
        S3Tracking.record(bucket: bucket, region: region, key: key) // so deleting the recording can clean this up
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
        _ = try? await readOrDelete(method: "DELETE", bucket: bucket, key: key, region: region)
    }

    static func get(bucket: String, key: String, region: String) async throws -> Data {
        try await readOrDelete(method: "GET", bucket: bucket, key: key, region: region)
    }

    private static func readOrDelete(method: String, bucket: String, key: String, region: String) async throws -> Data {
        let url = objectURL(bucket: bucket, region: region, key: key)
        var request = URLRequest(url: url)
        request.httpMethod = method
        let headers = ["x-amz-content-sha256": AWSSigV4Signer.hex(SHA256Digest.of(Data()))]
        let signer = try TranscribeSettings.signer(service: "s3", region: region)
        for (name, value) in headers.merging(signer.signedHeaders(method: method, url: url, headers: headers, body: Data()), uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try await AWSHTTP.send(request, service: "Amazon S3")
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
        let signer = try TranscribeSettings.signer(service: "transcribe", region: region)
        return try await AWSHTTP.jsonCall(url: url, target: "Transcribe.\(action)", body: body, signer: signer, service: "Amazon Transcribe")
    }

    static func mediaFormat(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "mp3": return "mp3"
        case "mp4": return "mp4"
        case "m4a": return "m4a"
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
        let speakers = Set(results.flatMap { result -> [String] in
            let alternative = (result["Alternatives"] as? [[String: Any]])?.first
            return (alternative?["Items"] as? [[String: Any]] ?? []).compactMap { $0["Speaker"] as? String }
        })
        for result in results where result["IsPartial"] as? Bool != true {
            guard let alternative = (result["Alternatives"] as? [[String: Any]])?.first else { continue }
            let items = alternative["Items"] as? [[String: Any]] ?? []
            if !items.contains(where: { $0["Speaker"] is String }) {
                let text = (alternative["Transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                output.append(TranscriptSegment(start: offset + (number(result["StartTime"]) ?? 0), end: offset + (number(result["EndTime"]) ?? 0),
                                                speaker: track, text: text))
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
    static func transcribe(fileURL: URL, track: String, offset: Double) async throws -> [TranscriptSegment] {
        let region = TranscribeSettings.region
        let bucket = TranscribeSettings.bucket
        try TranscribeSettings.validate(region: region, bucket: bucket)
        let jobName = "macpilot-\(UUID().uuidString.lowercased())"
        guard let format = TranscribeAPI.mediaFormat(for: fileURL) else { throw TranscribeError.unreadableAudio }
        let key = "\(TranscribeSettings.keyPrefix)\(jobName)/audio.\(fileURL.pathExtension.lowercased())"

        try await S3Client.put(fileURL: fileURL, bucket: bucket, key: key, region: region)
        var terminal = false
        let deleteAfter = TranscribeSettings.deleteAfter
        defer {
            if deleteAfter && terminal {
                Task {
                    await S3Client.delete(bucket: bucket, key: key, region: region)
                    _ = try? await TranscribeAPI.call("DeleteTranscriptionJob", ["TranscriptionJobName": jobName], region: region)
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
                terminal = true
                guard let uri = (job["Transcript"] as? [String: Any])?["TranscriptFileUri"] as? String, let url = URL(string: uri) else {
                    throw TranscribeError.jobFailed("no transcript file")
                }
                let json: [String: Any]
                do {
                    let data = try await AWSHTTP.send(URLRequest(url: url), service: "Amazon Transcribe")
                    json = try AWSHTTP.jsonObject(data, service: "Amazon Transcribe")
                } catch {
                    // A transport error may contain the presigned download URL.
                    throw TranscribeError.jobFailed("The transcript download failed.")
                }
                guard json["results"] is [String: Any] else {
                    throw TranscribeError.jobFailed("Amazon Transcribe returned no transcript results.")
                }
                return TranscribeParsing.batchSegments(json, offset: offset, track: track, duration: await AudioTools.duration(of: fileURL))
            case "FAILED":
                terminal = true
                throw TranscribeError.jobFailed(job["FailureReason"] as? String ?? "The Amazon Transcribe batch job failed.")
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
    private let audio: AsyncStream<Data>.Continuation
    private let chunks: AsyncStream<Data>
    private var task: Task<Void, Error>?

    init(onUpdate: @escaping @Sendable (Update) -> Void) {
        self.onUpdate = onUpdate
        (chunks, audio) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(400))
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
        let region = TranscribeSettings.region
        try TranscribeSettings.validate(region: region)
        let signer = try TranscribeSettings.signer(service: "transcribe", region: region)
        let url = signer.presignedURL(Self.url(region: region, language: TranscribeSettings.language,
                                               speakers: TranscribeSettings.identifySpeakers), expires: 300)
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 4 * 1024 * 1024
        socket.resume()
        let onUpdate = onUpdate
        let chunks = chunks
        let audio = audio
        task = Task {
            defer {
                audio.finish()
                socket.cancel(with: .normalClosure, reason: nil)
            }
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await chunk in chunks {
                            try await socket.send(.data(EventStream.audioEvent(chunk)))
                        }
                        try Task.checkCancellation()
                        try await socket.send(.data(EventStream.audioEvent(Data()))) // end of audio
                    }
                    group.addTask {
                        var buffer = Data()
                        while true {
                            let message: URLSessionWebSocketTask.Message
                            do {
                                message = try await socket.receive()
                            } catch {
                                if socket.closeCode == .normalClosure && buffer.isEmpty { return }
                                throw Self.connectionError(error)
                            }
                            guard case .data(let data) = message else { continue }
                            buffer.append(data)
                            for event in try EventStream.decode(&buffer) {
                                let json = (try? JSONSerialization.jsonObject(with: event.payload)) as? [String: Any] ?? [:]
                                if ["exception", "error"].contains(event.headers[":message-type"] ?? "") {
                                    throw TranscribeError.stream(Redactor.redact((json["Message"] ?? json["message"]) as? String ?? event.headers[":exception-type"] ?? "AWS rejected the audio stream."))
                                }
                                guard event.headers[":event-type"] == "TranscriptEvent",
                                      let results = (json["Transcript"] as? [String: Any])?["Results"] as? [[String: Any]] else { continue }
                                let partial = results.first { $0["IsPartial"] as? Bool == true }
                                    .flatMap { (($0["Alternatives"] as? [[String: Any]])?.first?["Transcript"] as? String) }
                                onUpdate(Update(partial: partial, finals: results.filter { $0["IsPartial"] as? Bool != true }))
                            }
                        }
                    }
                    do {
                        while try await group.next() != nil {}
                    } catch {
                        audio.finish()
                        socket.cancel(with: .goingAway, reason: nil)
                        group.cancelAll()
                        throw Self.connectionError(error)
                    }
                }
            } onCancel: {
                audio.finish()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private static func connectionError(_ error: Error) -> Error {
        // URLSession errors can contain the signed WebSocket URL.
        if error is TranscribeError || error is CancellationError { return error }
        return TranscribeError.stream("The connection to Amazon Transcribe ended (code \((error as NSError).code)). Check the AWS region, credentials, and WebSocket permission.")
    }

    @discardableResult
    func send(_ pcm: Data) -> Bool {
        if case .enqueued = audio.yield(pcm) { return true }
        return false
    }

    func wait() async throws { try await task?.value }

    /// Ends the audio and waits for the remaining results.
    func finish() async throws {
        audio.finish()
        let timeout = Task {
            try await Task.sleep(for: .seconds(15))
            cancel()
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await wait()
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        audio.finish()
        task?.cancel()
    }

    /// Streams a saved file at its recorded sample rate.
    static func transcribe(fileURL: URL, track: String, offset: Double) async throws -> [TranscriptSegment] {
        let collector = ResultCollector()
        let stream = TranscribeStream { update in collector.add(update.finals) }
        try stream.start()
        defer { stream.cancel() }
        let clock = ContinuousClock()
        var nextFrame = clock.now
        try await PCM16.readFile(fileURL) { chunk in
            guard stream.send(chunk) else {
                try await stream.finish()
                throw TranscribeError.stream("The audio stream stopped accepting data.")
            }
            let duration = Double(chunk.count) / 32_000
            nextFrame = nextFrame.advanced(by: .seconds(duration))
            try await clock.sleep(until: nextFrame)
        }
        try await stream.finish()
        return TranscribeParsing.streamingSegments(collector.results, offset: offset, track: track)
    }
}

final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: Any]] = []
    private var resultIDs = Set<String>()

    func add(_ results: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        for result in results {
            if let id = result["ResultId"] as? String, !resultIDs.insert(id).inserted { continue }
            stored.append(result)
        }
    }
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
    static func readFile(_ url: URL, chunk: (Data) async throws -> Void) async throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw TranscribeError.unreadableAudio }
        let converter = PCM16()
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw TranscribeError.unreadableAudio }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            if let data = converter.convert(buffer) { try await chunk(data) }
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
