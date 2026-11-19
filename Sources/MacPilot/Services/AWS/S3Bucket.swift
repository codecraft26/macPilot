import CryptoKit
import Foundation

/// Checks for the transcription bucket and creates it when it doesn't exist.
enum S3Bucket {
    enum State: Equatable {
        case exists
        case missing
        case otherRegion(String?)
        case noAccess
    }

    enum BucketError: LocalizedError {
        case invalidName(String)
        case otherRegion(bucket: String, region: String?)
        case noAccess(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let reason): return "S3 bucket name: \(reason)"
            case let .otherRegion(bucket, region):
                return "The bucket “\(bucket)” is in \(region ?? "another region"). Set the same region in Settings → Routing, or use a bucket in \(TranscribeSettings.region)."
            case .noAccess(let bucket):
                return "The bucket “\(bucket)” exists but this AWS key can't use it (it may belong to another account; bucket names are global). Choose a different name."
            }
        }
    }

    /// AWS naming rules (general purpose buckets). Returns a reason when invalid.
    static func nameProblem(_ name: String) -> String? {
        guard (3...63).contains(name.count) else { return "use 3 to 63 characters." }
        guard name.range(of: #"^[a-z0-9][a-z0-9.-]*[a-z0-9]$"#, options: .regularExpression) != nil else {
            return "use lowercase letters, numbers, dots and hyphens, starting and ending with a letter or number."
        }
        guard !name.contains(".."), !name.contains(".-"), !name.contains("-.") else { return "don't put dots next to dots or hyphens." }
        guard name.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) == nil else { return "it can't look like an IP address." }
        guard !name.hasPrefix("xn--"), !name.hasPrefix("sthree-"), !name.hasSuffix("-s3alias"), !name.hasSuffix("--ol-s3") else {
            return "that prefix or suffix is reserved by AWS."
        }
        return nil
    }

    /// A name that is very likely to be free, e.g. "macpilot-transcribe-us-east-1-k3x9q2".
    static func suggestedName(region: String) -> String {
        let suffix = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        return "macpilot-transcribe-\(region)-\(suffix)"
    }

    static func createBody(region: String) -> Data? {
        guard region != "us-east-1" else { return nil } // us-east-1 takes no location constraint
        return Data("""
        <CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><LocationConstraint>\(region)</LocationConstraint></CreateBucketConfiguration>
        """.utf8)
    }

    /// Temporary uploads under the MacPilot prefix expire after a day, as a safety net.
    static func lifecycleBody(prefix: String) -> Data {
        Data("""
        <LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule><ID>macpilot-temporary-audio</ID><Filter><Prefix>\(prefix)</Prefix></Filter><Status>Enabled</Status><Expiration><Days>1</Days></Expiration><AbortIncompleteMultipartUpload><DaysAfterInitiation>1</DaysAfterInitiation></AbortIncompleteMultipartUpload></Rule></LifecycleConfiguration>
        """.utf8)
    }

    private static func request(_ method: String, bucket: String, region: String, query: [URLQueryItem] = [], body: Data = Data(),
                                extraHeaders: [String: String] = [:]) throws -> URLRequest {
        var components = URLComponents(string: "https://s3.\(region).amazonaws.com/\(bucket)")!
        if !query.isEmpty {
            components.percentEncodedQuery = AWSSigV4Signer.canonicalQuery(query)
        }
        let url = components.url!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        var headers = extraHeaders
        headers["x-amz-content-sha256"] = AWSSigV4Signer.hex(SHA256Digest.of(body))
        let signer = try TranscribeSettings.signer(service: "s3", region: region)
        for (name, value) in headers.merging(signer.signedHeaders(method: method, url: url, headers: headers, body: body), uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !body.isEmpty { request.httpBody = body }
        return request
    }

    static func state(bucket: String, region: String) async throws -> State {
        let (_, response) = try await HTTPSupport.session.data(for: try request("HEAD", bucket: bucket, region: region))
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: return .exists
        case 404: return .missing
        case 301, 400: return .otherRegion(http?.value(forHTTPHeaderField: "x-amz-bucket-region"))
        case 403: return .noAccess
        default: return .noAccess
        }
    }

    /// Creates the bucket (private, S3-managed encryption by default) and adds the one-day cleanup rule.
    /// Returns a note when the optional cleanup rule couldn't be set.
    @discardableResult
    static func create(bucket: String, region: String, prefix: String) async throws -> String? {
        if let problem = nameProblem(bucket) { throw BucketError.invalidName(problem) }
        let body = createBody(region: region) ?? Data()
        _ = try await AWSHTTP.send(try request("PUT", bucket: bucket, region: region, body: body,
                                               extraHeaders: body.isEmpty ? [:] : ["content-type": "application/xml"]),
                                   service: "Amazon S3")
        guard !prefix.isEmpty else { return nil }
        let rules = lifecycleBody(prefix: prefix)
        let md5 = Data(Insecure.MD5.hash(data: rules)).base64EncodedString()
        do {
            _ = try await AWSHTTP.send(try request("PUT", bucket: bucket, region: region, query: [URLQueryItem(name: "lifecycle", value: "")],
                                                   body: rules, extraHeaders: ["content-type": "application/xml", "content-md5": md5]),
                                       service: "Amazon S3")
            return nil
        } catch {
            return "Bucket created, but the 1-day cleanup rule wasn't added (needs s3:PutLifecycleConfiguration)."
        }
    }

    // MARK: Before uploading

    @MainActor private static var verified: Set<String> = []

    /// Makes sure the configured bucket exists in the region, creating it if needed (once per session).
    static func ensure(bucket: String, region: String) async throws {
        let key = "\(region)/\(bucket)"
        if await MainActor.run(body: { verified.contains(key) }) { return }
        switch try await state(bucket: bucket, region: region) {
        case .exists:
            break
        case .missing:
            try await create(bucket: bucket, region: region, prefix: TranscribeSettings.keyPrefix)
        case .otherRegion(let actual):
            throw BucketError.otherRegion(bucket: bucket, region: actual)
        case .noAccess:
            throw BucketError.noAccess(bucket)
        }
        await MainActor.run { _ = verified.insert(key) }
    }
}
