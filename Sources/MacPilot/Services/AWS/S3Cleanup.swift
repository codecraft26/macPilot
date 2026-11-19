import Foundation

/// A folder MacPilot used in S3 for one transcription job.
struct S3Location: Codable, Hashable {
    var bucket: String
    var region: String
    var prefix: String

    var displayPath: String { "s3://\(bucket)/\(prefix)" }

    /// "macpilot/<job-id>/input/audio.m4a" → "macpilot/<job-id>/" (the job's own folder under the key prefix).
    static func jobPrefix(forKey key: String, keyPrefix: String) -> String? {
        let rest = key.hasPrefix(keyPrefix) ? String(key.dropFirst(keyPrefix.count)) : key
        guard let first = rest.split(separator: "/", omittingEmptySubsequences: true).first, rest.contains("/") else { return nil }
        return keyPrefix + first + "/"
    }
}

/// Collects the S3 folders touched while transcribing one recording (task-local, so concurrent jobs don't mix).
final class S3Tracking: @unchecked Sendable {
    @TaskLocal static var current: S3Tracking?

    private let lock = NSLock()
    private var stored: [S3Location] = []

    func add(_ location: S3Location) {
        lock.lock()
        if !stored.contains(location) { stored.append(location) }
        lock.unlock()
    }

    var locations: [S3Location] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    static func record(bucket: String, region: String, key: String) {
        guard let current, let prefix = S3Location.jobPrefix(forKey: key, keyPrefix: TranscribeSettings.keyPrefix) else { return }
        current.add(S3Location(bucket: bucket, region: region, prefix: prefix))
    }
}

extension S3Client {
    /// Keys under a prefix (ListObjectsV2, all pages). Needs s3:ListBucket.
    static func list(bucket: String, prefix: String, region: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            var components = URLComponents(string: "https://s3.\(region).amazonaws.com/\(bucket)")!
            var items = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "prefix", value: prefix)]
            if let token { items.append(URLQueryItem(name: "continuation-token", value: token)) }
            components.queryItems = items
            // Keep S3's own encoding rules for the signed query.
            components.percentEncodedQuery = AWSSigV4Signer.canonicalQuery(items)
            let url = components.url!
            var request = URLRequest(url: url)
            let headers = ["x-amz-content-sha256": AWSSigV4Signer.hex(SHA256Digest.of(Data()))]
            let signer = try TranscribeSettings.signer(service: "s3", region: region)
            for (name, value) in headers.merging(signer.signedHeaders(method: "GET", url: url, headers: headers, body: Data()), uniquingKeysWith: { $1 }) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let data = try await AWSHTTP.send(request, service: "Amazon S3")
            let page = parseList(data)
            keys += page.keys
            token = page.nextToken
        } while token != nil
        return keys
    }

    static func parseList(_ data: Data) -> (keys: [String], nextToken: String?) {
        let xml = String(decoding: data, as: UTF8.self)
        func values(_ tag: String) -> [String] {
            var result: [String] = []
            var searchRange = xml.startIndex..<xml.endIndex
            while let open = xml.range(of: "<\(tag)>", range: searchRange),
                  let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) {
                result.append(String(xml[open.upperBound..<close.lowerBound])
                    .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&apos;", with: "'"))
                searchRange = close.upperBound..<xml.endIndex
            }
            return result
        }
        let truncated = values("IsTruncated").first == "true"
        return (values("Key"), truncated ? values("NextContinuationToken").first : nil)
    }

    /// Deletes every object under `prefix`. Returns how many were deleted.
    @discardableResult
    static func deletePrefix(bucket: String, prefix: String, region: String) async throws -> Int {
        guard !prefix.isEmpty else { return 0 } // never wipe a whole bucket
        let keys = try await list(bucket: bucket, prefix: prefix, region: region)
        for key in keys {
            _ = try await deleteObject(bucket: bucket, key: key, region: region)
        }
        return keys.count
    }

    static func deleteObject(bucket: String, key: String, region: String) async throws {
        let url = objectURL(bucket: bucket, region: region, key: key)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let headers = ["x-amz-content-sha256": AWSSigV4Signer.hex(SHA256Digest.of(Data()))]
        let signer = try TranscribeSettings.signer(service: "s3", region: region)
        for (name, value) in headers.merging(signer.signedHeaders(method: "DELETE", url: url, headers: headers, body: Data()), uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        _ = try await AWSHTTP.send(request, service: "Amazon S3")
    }
}
