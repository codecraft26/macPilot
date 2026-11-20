import CryptoKit
import Foundation

/// AWS Signature Version 4 request signing (HMAC-SHA256), used for Claude in Amazon Bedrock.
/// See https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
struct AWSSigV4Signer {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?
    var region: String
    var service: String

    /// Headers to add to the request: `Authorization`, `X-Amz-Date` and, with temporary credentials,
    /// `X-Amz-Security-Token`. Every header in `headers` is signed, plus `host` and `x-amz-date`.
    func signedHeaders(method: String, url: URL, headers: [String: String], body: Data, date: Date = Date()) -> [String: String] {
        let amzDate = Self.amzDateFormatter.string(from: date)
        let day = String(amzDate.prefix(8))

        var toSign: [String: String] = [:]
        for (name, value) in headers { toSign[name.lowercased()] = value }
        toSign["host"] = Self.host(of: url)
        toSign["x-amz-date"] = amzDate
        if let sessionToken, !sessionToken.isEmpty { toSign["x-amz-security-token"] = sessionToken }

        let sortedNames = toSign.keys.sorted()
        let canonicalHeaders = sortedNames.map { "\($0):\(Self.trimValue(toSign[$0] ?? ""))\n" }.joined()
        let signedHeaderList = sortedNames.joined(separator: ";")
        let payloadHash = Self.hex(SHA256.hash(data: body))

        let canonicalRequest = [
            method.uppercased(),
            Self.canonicalPath(url),
            Self.canonicalQuery(url),
            canonicalHeaders,
            signedHeaderList,
            payloadHash
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))
        ].joined(separator: "\n")

        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey(day: day)))

        var result = [
            "Authorization": "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaderList), Signature=\(signature)",
            "X-Amz-Date": amzDate
        ]
        if let sessionToken, !sessionToken.isEmpty { result["X-Amz-Security-Token"] = sessionToken }
        return result
    }

    /// A presigned URL (query-string authentication), e.g. for the Amazon Transcribe WebSocket.
    /// Only the `host` header is signed and the payload hash is that of an empty body.
    func presignedURL(_ url: URL, expires: Int = 300, date: Date = Date()) -> URL {
        let amzDate = Self.amzDateFormatter.string(from: date)
        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential", value: "\(accessKeyID)/\(scope)"),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: String(expires)),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host")
        ]
        if let sessionToken, !sessionToken.isEmpty {
            items.append(URLQueryItem(name: "X-Amz-Security-Token", value: sessionToken))
        }
        let canonicalQuery = Self.canonicalQuery(items)
        let canonicalRequest = [
            "GET",
            Self.canonicalPath(url),
            canonicalQuery,
            "host:\(Self.host(of: url))\n",
            "host",
            Self.hex(SHA256.hash(data: Data()))
        ].joined(separator: "\n")
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))
        ].joined(separator: "\n")
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey(day: day)))
        components.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=" + signature
        return components.url!
    }

    func signingKey(day: String) -> SymmetricKey {
        func hmac(_ key: SymmetricKey, _ text: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)))
        }
        let kDate = hmac(SymmetricKey(data: Data(("AWS4" + secretAccessKey).utf8)), day)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        return hmac(kService, "aws4_request")
    }

    // MARK: Helpers

    static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func host(of url: URL) -> String {
        let host = url.host ?? ""
        if let port = url.port, !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) {
            return "\(host):\(port)"
        }
        return host
    }

    /// RFC 3986 unreserved characters stay; everything else is percent-encoded.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func canonicalPath(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard !path.isEmpty else { return "/" }
        // Normalize: decode then encode each segment once (non-S3 services encode the path again,
        // which is a no-op for paths made of unreserved characters like Bedrock's).
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0).removingPercentEncoding ?? String($0)) }
            .joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        canonicalQuery(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
    }

    static func canonicalQuery(_ items: [URLQueryItem]) -> String {
        guard !items.isEmpty else { return "" }
        let pairs: [(name: String, value: String)] = items.map { item in
            (name: encode(item.name), value: encode(item.value ?? ""))
        }
        let sorted = pairs.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return sorted.map { pair in pair.name + "=" + pair.value }.joined(separator: "&")
    }

    static func trimValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
