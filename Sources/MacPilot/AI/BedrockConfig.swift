import Foundation

/// How MacPilot authenticates to Claude in Amazon Bedrock.
enum BedrockAuthMethod: String, CaseIterable, Identifiable {
    case accessKeys = "keys"
    case apiKey = "apiKey"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .accessKeys: return "Access key"
        case .apiKey: return "Bedrock API key"
        }
    }
}

/// Bedrock settings. Secrets live only in the Keychain; region, auth method and model in UserDefaults.
enum BedrockConfig {
    enum Account {
        static let accessKeyID = "bedrock.accessKeyId"
        static let secretAccessKey = "bedrock.secretAccessKey"
        static let sessionToken = "bedrock.sessionToken"
        static let apiKey = "bedrock.apiKey"
        static let all = [accessKeyID, secretAccessKey, sessionToken, apiKey]
    }

    static let defaultRegion = "us-east-1"
    static let suggestedRegions = ["us-east-1", "us-east-2", "us-west-2", "eu-west-1", "eu-north-1", "ap-northeast-1", "ap-southeast-4"]
    static let modelAccessURL = URL(string: "https://console.aws.amazon.com/bedrock/home#/modelaccess")!

    static var region: String {
        let value = (UserDefaults.standard.string(forKey: PrefKey.bedrockRegion) ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? defaultRegion : value
    }

    static var authMethod: BedrockAuthMethod {
        BedrockAuthMethod(rawValue: UserDefaults.standard.string(forKey: PrefKey.bedrockAuthMethod) ?? "") ?? .accessKeys
    }

    static var messagesURL: URL {
        URL(string: "https://bedrock-mantle.\(region).api.aws/anthropic/v1/messages")!
    }

    /// True when the selected auth method has what it needs (checked without reading secrets).
    static var isConfigured: Bool {
        switch authMethod {
        case .accessKeys:
            return KeychainStore.exists(account: Account.accessKeyID) && KeychainStore.exists(account: Account.secretAccessKey)
        case .apiKey:
            return KeychainStore.exists(account: Account.apiKey)
        }
    }

    static func deleteAll() {
        for account in Account.all { try? KeychainStore.delete(account: account) }
    }

    /// Authentication headers for one request (SigV4 signature or bearer token).
    static func authHeaders(method: String, url: URL, headers: [String: String], body: Data) throws -> [String: String] {
        switch authMethod {
        case .apiKey:
            guard let token = KeychainStore.read(account: Account.apiKey), !token.isEmpty else {
                throw AIError.missingKey(.bedrock)
            }
            return ["Authorization": "Bearer \(token)"]
        case .accessKeys:
            guard let keyID = KeychainStore.read(account: Account.accessKeyID), !keyID.isEmpty,
                  let secret = KeychainStore.read(account: Account.secretAccessKey), !secret.isEmpty else {
                throw AIError.missingKey(.bedrock)
            }
            let signer = AWSSigV4Signer(
                accessKeyID: keyID,
                secretAccessKey: secret,
                sessionToken: KeychainStore.read(account: Account.sessionToken),
                region: region,
                service: "bedrock-mantle"
            )
            return signer.signedHeaders(method: method, url: url, headers: headers, body: body)
        }
    }
}
