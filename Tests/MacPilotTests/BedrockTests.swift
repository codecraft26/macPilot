import XCTest
@testable import MacPilot

final class SigV4Tests: XCTestCase {
    /// AWS Signature Version 4 test suite credentials and date.
    private let signer = AWSSigV4Signer(
        accessKeyID: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        sessionToken: nil,
        region: "us-east-1",
        service: "service"
    )
    private let date = Date(timeIntervalSince1970: 1_440_938_160) // 2015-08-30T12:36:00Z

    func testGetVanilla() {
        let headers = signer.signedHeaders(method: "GET", url: URL(string: "https://example.amazonaws.com/")!, headers: [:], body: Data(), date: date)
        XCTAssertEqual(headers["X-Amz-Date"], "20150830T123600Z")
        XCTAssertEqual(headers["Authorization"],
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    func testPostVanilla() {
        let headers = signer.signedHeaders(method: "POST", url: URL(string: "https://example.amazonaws.com/")!, headers: [:], body: Data(), date: date)
        XCTAssertEqual(headers["Authorization"],
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b")
    }

    func testBedrockMantleRequestIsDeterministicAndIncludesToken() {
        var bedrock = signer
        bedrock.region = "us-west-2"
        bedrock.service = "bedrock-mantle"
        bedrock.sessionToken = "session-token"
        let url = URL(string: "https://bedrock-mantle.us-west-2.api.aws/anthropic/v1/messages")!
        let body = Data(#"{"model":"anthropic.claude-opus-5-5","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}"#.utf8)
        let headers = ["content-type": "application/json", "anthropic-version": "2026-10-21"]
        let first = bedrock.signedHeaders(method: "POST", url: url, headers: headers, body: body, date: date)
        let second = bedrock.signedHeaders(method: "POST", url: url, headers: headers, body: body, date: date)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first["X-Amz-Security-Token"], "session-token")
        let auth = first["Authorization"] ?? ""
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-west-2/bedrock-mantle/aws4_request, "))
        XCTAssertTrue(auth.contains("SignedHeaders=anthropic-version;content-type;host;x-amz-date;x-amz-security-token,"))
        // A different body must change the signature.
        let other = bedrock.signedHeaders(method: "POST", url: url, headers: headers, body: Data("{}".utf8), date: date)
        XCTAssertNotEqual(other["Authorization"], first["Authorization"])
    }
}

final class BedrockProviderTests: XCTestCase {
    func testProviderMetadata() {
        XCTAssertEqual(AIProviderID.bedrock.defaultModel, "anthropic.claude-opus-5-5")
        XCTAssertTrue(AIProviderID.bedrock.suggestedModels.allSatisfy { $0.hasPrefix("anthropic.") })
        XCTAssertFalse(AIProviderID.bedrock.suggestedModels.contains { $0.contains("fable") })
        XCTAssertTrue(AIProviderID.bedrock.isExternal)
    }

    func testRedactsAWSCredentials() {
        let text = "Credential=AKIAIOSFODNN7EXAMPLE/20260101/us-east-1/bedrock-mantle/aws4_request, Signature=abcdef0123456789 and ASIAZZZZZZZZZZZZZZZZ"
        let redacted = Redactor.redact(text)
        XCTAssertFalse(redacted.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertFalse(redacted.contains("abcdef0123456789"))
        XCTAssertFalse(redacted.contains("ASIAZZZZZZZZZZZZZZZZ"))
    }

    func testAWSErrorMessageIsRead() {
        XCTAssertEqual(HTTPSupport.errorMessage(from: Data(#"{"message":"You don't have access to the model"}"#.utf8)), "You don't have access to the model")
        let text = AIError.http(provider: .bedrock, status: 403, message: "Forbidden").errorDescription ?? ""
        XCTAssertTrue(text.contains("bedrock-mantle:CreateInference"))
    }
}

final class ProviderAutoSetupTests: XCTestCase {
    private let awsOnly = ProviderAutoSetup.Credentials(openAI: false, anthropic: false, awsAccessKeys: true, bedrock: true)

    func testAWSOnlyUsesTranscribeAndBedrock() {
        let choices = ProviderAutoSetup.decide(awsOnly, explicitTranscription: nil, explicitChat: nil, explicitAnalysis: nil)
        XCTAssertEqual(choices.transcription, "aws")
        XCTAssertEqual(choices.chat, "bedrock")
        XCTAssertEqual(choices.analysis, "bedrock")
    }

    func testRespectsRealChoices() {
        // Local Whisper chosen on purpose stays; OpenAI with a key stays.
        XCTAssertNil(ProviderAutoSetup.decide(awsOnly, explicitTranscription: "whisper", explicitChat: "ollama", explicitAnalysis: nil).transcription)
        XCTAssertNil(ProviderAutoSetup.decide(awsOnly, explicitTranscription: "whisper", explicitChat: "ollama", explicitAnalysis: nil).chat)
        let withOpenAI = ProviderAutoSetup.Credentials(openAI: true, anthropic: true, awsAccessKeys: true, bedrock: true)
        XCTAssertEqual(ProviderAutoSetup.decide(withOpenAI, explicitTranscription: nil, explicitChat: nil, explicitAnalysis: nil), .init())
    }

    func testBedrockAPIKeyAloneDoesNotPickTranscribe() {
        let apiKeyOnly = ProviderAutoSetup.Credentials(openAI: false, anthropic: false, awsAccessKeys: false, bedrock: true)
        let choices = ProviderAutoSetup.decide(apiKeyOnly, explicitTranscription: nil, explicitChat: nil, explicitAnalysis: nil)
        XCTAssertNil(choices.transcription)
        XCTAssertEqual(choices.chat, "bedrock")
    }
}
