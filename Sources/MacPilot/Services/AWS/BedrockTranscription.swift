import Foundation

/// Bedrock Data Automation produces a timestamped transcript from an audio file in S3.
enum BedrockTranscription {
    private static let service = "Amazon Bedrock Data Automation"

    static func supports(_ url: URL) -> Bool {
        ["amr", "flac", "m4a", "mp3", "ogg", "wav"].contains(url.pathExtension.lowercased())
    }

    static func transcribe(fileURL: URL, track: String, offset: Double) async throws -> [TranscriptSegment] {
        let region = TranscribeSettings.region
        let bucket = TranscribeSettings.bucket
        let profile = TranscribeSettings.dataProfile
        let project = TranscribeSettings.dataProject
        let deleteUpload = TranscribeSettings.deleteAfter
        try TranscribeSettings.validate(region: region, bucket: bucket)
        guard !bucket.isEmpty, !profile.isEmpty else {
            throw TranscribeError.configuration("Set an S3 bucket and a Data Automation profile ARN under Settings → Routing.")
        }
        let signer = try TranscribeSettings.signer(service: "bedrock", region: region)
        let jobID = UUID().uuidString.lowercased()
        let prefix = "\(TranscribeSettings.keyPrefix)\(jobID)/"
        let inputKey = prefix + "input/audio." + fileURL.pathExtension.lowercased()
        let outputPrefix = prefix + "output/"
        guard supports(fileURL) else {
            throw TranscribeError.configuration("Bedrock Data Automation needs AMR, FLAC, M4A, MP3, OGG, or WAV audio.")
        }
        try await S3Client.put(fileURL: fileURL, bucket: bucket, key: inputKey, region: region)
        var terminal = false
        defer {
            if deleteUpload && terminal {
                Task { await S3Client.delete(bucket: bucket, key: inputKey, region: region) }
            }
        }

        var body: [String: Any] = [
            "clientToken": jobID,
            "dataAutomationProfileArn": profile,
            "inputConfiguration": ["s3Uri": "s3://\(bucket)/\(inputKey)"],
            "outputConfiguration": ["s3Uri": "s3://\(bucket)/\(outputPrefix)"]
        ]
        if !project.isEmpty {
            body["dataAutomationConfiguration"] = ["dataAutomationProjectArn": project, "stage": "LIVE"]
        }
        let invocation = try await call("InvokeDataAutomationAsync", body, signer: signer)
        guard let arn = invocation["invocationArn"] as? String else {
            throw TranscribeError.jobFailed("Bedrock Data Automation returned no invocation ARN.")
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(7200))
        var delay = 2.0
        while clock.now < deadline {
            try await Task.sleep(for: .seconds(delay))
            delay = min(delay * 1.5, 15)
            let status = try await call("GetDataAutomationStatus", ["invocationArn": arn], signer: signer)
            switch status["status"] as? String {
            case "Success":
                terminal = true
                let output = status["outputConfiguration"] as? [String: Any]
                let metadataKey = try objectKey(output?["s3Uri"] as? String, bucket: bucket, prefix: outputPrefix)
                let metadata = try await read(metadataKey, bucket: bucket, region: region)
                let paths = standardOutputPaths(metadata)
                guard !paths.isEmpty else {
                    throw TranscribeError.jobFailed("Bedrock Data Automation returned no standard audio output.")
                }
                var tracks: [[TranscriptSegment]] = []
                for path in paths {
                    let key = try objectKey(path, bucket: bucket, prefix: outputPrefix)
                    let data = try await read(key, bucket: bucket, region: region)
                    tracks.append(try segments(data, track: track, offset: offset))
                }
                return TranscriptMerger.merge(tracks)
            case "ClientError", "ServiceError":
                terminal = true
                let reason = status["errorMessage"] as? String ?? "Bedrock Data Automation failed."
                throw TranscribeError.jobFailed(Redactor.redact(reason))
            case "Created", "InProgress":
                continue
            default:
                throw TranscribeError.jobFailed("Bedrock Data Automation returned an unknown invocation status.")
            }
        }
        throw TranscribeError.timedOut
    }

    private static func call(_ action: String, _ body: [String: Any], signer: AWSSigV4Signer) async throws -> [String: Any] {
        let url = URL(string: "https://bedrock-data-automation-runtime.\(signer.region).amazonaws.com/")!
        return try await AWSHTTP.jsonCall(
            url: url, target: "AmazonBedrockKeystoneRuntimeService.\(action)", body: body, signer: signer, service: service
        )
    }

    private static func read(_ key: String, bucket: String, region: String) async throws -> [String: Any] {
        let data = try await S3Client.get(bucket: bucket, key: key, region: region)
        return try AWSHTTP.jsonObject(data, service: service)
    }

    static func objectKey(_ uri: String?, bucket: String, prefix: String) throws -> String {
        let base = "s3://\(bucket)/"
        guard let uri, uri.hasPrefix(base + prefix), uri.count > (base + prefix).count else {
            throw TranscribeError.jobFailed("Bedrock Data Automation returned a path outside the job's S3 output folder.")
        }
        let key = String(uri.dropFirst(base.count))
        guard !key.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw TranscribeError.jobFailed("Bedrock Data Automation returned an invalid S3 object path.")
        }
        return key
    }

    static func standardOutputPaths(_ metadata: [String: Any]) -> [String] {
        let assets = metadata["output_metadata"] as? [[String: Any]] ?? []
        return assets.flatMap { asset in
            (asset["segment_metadata"] as? [[String: Any]] ?? []).compactMap { $0["standard_output_path"] as? String }
        }
    }

    static func segments(_ output: [String: Any], track: String, offset: Double) throws -> [TranscriptSegment] {
        guard let items = output["audio_segments"] as? [[String: Any]] else {
            throw TranscribeError.jobFailed("Bedrock Data Automation returned no transcript segments. Enable full transcription in your project's audio standard output.")
        }
        let speakers = Set(items.compactMap { ($0["speaker"] as? [String: Any])?["speaker_label"] as? String })
        return items.compactMap { item in
            guard item["type"] as? String == "TRANSCRIPT",
                  let start = item["start_timestamp_millis"] as? Double,
                  let end = item["end_timestamp_millis"] as? Double,
                  start >= 0, end >= start, end.isFinite,
                  let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let speaker = (item["speaker"] as? [String: Any])?["speaker_label"] as? String
            return TranscriptSegment(start: offset + start / 1000, end: offset + end / 1000,
                                     speaker: TranscribeParsing.speakerName(speaker, track: track, multipleSpeakers: speakers.count > 1), text: text)
        }
    }
}
