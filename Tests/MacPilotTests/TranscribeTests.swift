import XCTest
@testable import MacPilot

final class EventStreamTests: XCTestCase {
    func testCRC32CheckValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testRoundTripAndCorruptionDetection() throws {
        let frame = EventStream.encode(headers: [(":message-type", "event"), (":event-type", "TranscriptEvent")], payload: Data(#"{"a":1}"#.utf8))
        var buffer = frame + frame.prefix(10) // one full frame and a partial one
        let messages = try EventStream.decode(&buffer)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.headers[":event-type"], "TranscriptEvent")
        XCTAssertEqual(messages.first?.payload, Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(buffer.count, 10, "incomplete frame stays buffered")

        var corrupted = frame
        corrupted[corrupted.count - 6] ^= 0xFF
        XCTAssertThrowsError(try EventStream.decode(&corrupted))

        let audio = EventStream.audioEvent(Data([1, 2, 3, 4]))
        var audioBuffer = audio
        XCTAssertEqual(try EventStream.decode(&audioBuffer).first?.headers[":event-type"], "AudioEvent")
    }
}

final class TranscribeSigningTests: XCTestCase {
    func testPresignedWebSocketURL() {
        let signer = AWSSigV4Signer(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                    sessionToken: nil, region: "us-east-1", service: "transcribe")
        let base = TranscribeStream.url(region: "us-east-1", language: "en-US", speakers: true)
        let url = signer.presignedURL(base, expires: 300, date: Date(timeIntervalSince1970: 1_440_938_160))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "transcribestreaming.us-east-1.amazonaws.com")
        XCTAssertEqual(url.port, 8443)
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("X-Amz-Credential=AKIDEXAMPLE%2F20150830%2Fus-east-1%2Ftranscribe%2Faws4_request"))
        // Expected signature computed independently (Python hmac/hashlib) from the same inputs.
        XCTAssertTrue(query.hasSuffix("X-Amz-Signature=8fad0bb735da38dd9bca1a68d4827d1f6784ab77979822f94eaf1edb68e55424"), query)
    }

    func testS3URLAndMediaFormats() {
        XCTAssertEqual(S3Client.objectURL(bucket: "my-bucket", region: "eu-west-1", key: "macpilot/abc/my file.m4a").absoluteString,
                       "https://s3.eu-west-1.amazonaws.com/my-bucket/macpilot/abc/my%20file.m4a") // path-style
        XCTAssertEqual(TranscribeAPI.mediaFormat(for: URL(fileURLWithPath: "/a/b.m4a")), "m4a")
        XCTAssertEqual(TranscribeAPI.mediaFormat(for: URL(fileURLWithPath: "/a/b.MP3")), "mp3")
        XCTAssertEqual(TranscribeAPI.mediaFormat(for: URL(fileURLWithPath: "/a/b.flac")), "flac")
        XCTAssertNil(TranscribeAPI.mediaFormat(for: URL(fileURLWithPath: "/a/b.xyz")))
    }
}

final class TranscribeParsingTests: XCTestCase {
    func testBatchAudioSegmentsWithSpeakers() {
        let json: [String: Any] = ["results": [
            "speaker_labels": ["segments": [["speaker_label": "spk_0"], ["speaker_label": "spk_1"]]],
            "audio_segments": [
                ["transcript": "Hello team.", "start_time": "0.5", "end_time": "1.8", "speaker_label": "spk_0"],
                ["transcript": "Hi there.", "start_time": "2.0", "end_time": "3.1", "speaker_label": "spk_1"]
            ]
        ]]
        let others = TranscribeParsing.batchSegments(json, offset: 10, track: "Others", duration: nil)
        XCTAssertEqual(others.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(others.first?.start ?? 0, 10.5, accuracy: 0.001)
        let mine = TranscribeParsing.batchSegments(json, offset: 0, track: "Me", duration: nil)
        XCTAssertEqual(mine.map(\.speaker), ["Me", "Room speaker 2"])
    }

    func testStreamingFinalsSplitBySpeaker() {
        let results: [[String: Any]] = [
            ["IsPartial": true, "Alternatives": [["Transcript": "ignored"]]],
            ["IsPartial": false, "StartTime": 0.0, "EndTime": 2.0, "Alternatives": [["Transcript": "Yes. No.", "Items": [
                ["Content": "Yes", "StartTime": 0.0, "EndTime": 0.4, "Type": "pronunciation", "Speaker": "0"],
                ["Content": ".", "Type": "punctuation"],
                ["Content": "No", "StartTime": 1.0, "EndTime": 1.4, "Type": "pronunciation", "Speaker": "1"],
                ["Content": ".", "Type": "punctuation"]
            ]]]]
        ]
        let segments = TranscribeParsing.streamingSegments(results, offset: 0, track: "Others")
        XCTAssertEqual(segments.map(\.text), ["Yes.", "No."])
        XCTAssertEqual(segments.map(\.speaker), ["Speaker 1", "Speaker 2"])
    }
}

final class S3CleanupTests: XCTestCase {
    func testJobPrefix() {
        XCTAssertEqual(S3Location.jobPrefix(forKey: "macpilot/macpilot-abc/audio.m4a", keyPrefix: "macpilot/"), "macpilot/macpilot-abc/")
        XCTAssertEqual(S3Location.jobPrefix(forKey: "macpilot/job1/input/audio.m4a", keyPrefix: "macpilot/"), "macpilot/job1/")
        XCTAssertEqual(S3Location.jobPrefix(forKey: "job2/audio.wav", keyPrefix: ""), "job2/")
        XCTAssertNil(S3Location.jobPrefix(forKey: "macpilot/audio.m4a", keyPrefix: "macpilot/"), "never the whole prefix")
    }

    func testListParsing() {
        let xml = """
        <ListBucketResult><IsTruncated>true</IsTruncated>
        <Contents><Key>macpilot/j1/audio.m4a</Key></Contents>
        <Contents><Key>macpilot/j1/output/a&amp;b.json</Key></Contents>
        <NextContinuationToken>tok123</NextContinuationToken></ListBucketResult>
        """
        let page = S3Client.parseList(Data(xml.utf8))
        XCTAssertEqual(page.keys, ["macpilot/j1/audio.m4a", "macpilot/j1/output/a&b.json"])
        XCTAssertEqual(page.nextToken, "tok123")
        XCTAssertNil(S3Client.parseList(Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8)).nextToken)
    }

    func testTrackingIsTaskLocal() async {
        let tracking = S3Tracking()
        await S3Tracking.$current.withValue(tracking) {
            S3Tracking.record(bucket: "b", region: "us-east-1", key: TranscribeSettings.keyPrefix + "job9/audio.m4a")
            S3Tracking.record(bucket: "b", region: "us-east-1", key: TranscribeSettings.keyPrefix + "job9/output/x.json")
        }
        S3Tracking.record(bucket: "b", region: "us-east-1", key: "outside/job/audio.m4a") // no collector: ignored
        XCTAssertEqual(tracking.locations, [S3Location(bucket: "b", region: "us-east-1", prefix: TranscribeSettings.keyPrefix + "job9/")])
    }
}

final class S3BucketTests: XCTestCase {
    func testBucketNameRules() {
        XCTAssertNil(S3Bucket.nameProblem("macpilot-transcribe-us-east-1-abc123"))
        XCTAssertNil(S3Bucket.nameProblem("my.bucket.name"))
        XCTAssertNotNil(S3Bucket.nameProblem("ab"))
        XCTAssertNotNil(S3Bucket.nameProblem("My_Bucket"))
        XCTAssertNotNil(S3Bucket.nameProblem("-bucket"))
        XCTAssertNotNil(S3Bucket.nameProblem("bad..dots"))
        XCTAssertNotNil(S3Bucket.nameProblem("192.168.1.10"))
        XCTAssertNotNil(S3Bucket.nameProblem("xn--bucket"))
    }

    func testSuggestedNameIsValid() {
        for region in ["us-east-1", "ap-southeast-4", "eu-north-1"] {
            let name = S3Bucket.suggestedName(region: region)
            XCTAssertNil(S3Bucket.nameProblem(name), name)
            XCTAssertTrue(name.contains(region))
        }
    }

    func testCreateAndLifecycleBodies() {
        XCTAssertNil(S3Bucket.createBody(region: "us-east-1"))
        let body = String(decoding: S3Bucket.createBody(region: "eu-west-1") ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("<LocationConstraint>eu-west-1</LocationConstraint>"))
        let rules = String(decoding: S3Bucket.lifecycleBody(prefix: "macpilot/"), as: UTF8.self)
        XCTAssertTrue(rules.contains("<Prefix>macpilot/</Prefix>"))
        XCTAssertTrue(rules.contains("<Days>1</Days>"))
    }
}
