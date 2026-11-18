import Foundation
import SwiftData

@MainActor
enum Persistence {
    static let schema = Schema([
        Conversation.self,
        ChatMessage.self,
        PromptTemplate.self,
        Note.self,
        TaskItem.self
    ])

    static let storeDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let container: ModelContainer = {
        let url = storeDirectory.appendingPathComponent("MacPilot.store")
        let configuration = ModelConfiguration(schema: schema, url: url)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not open the MacPilot data store: \(error)")
        }
    }()
}

@MainActor
enum Seeder {
    private static let seededKey = "seed.promptLibrary.v1"

    static func seedIfNeeded(_ context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seededKey) else { return }
        let prompts: [(String, String, String)] = [
            ("Summarize", "Summarize the following in 5 concise bullet points, then list any action items:\n\n", "Writing"),
            ("Rewrite professionally", "Rewrite the following to be clear, friendly and professional. Keep it short:\n\n", "Writing"),
            ("Explain this code", "Explain what this code does, step by step, and point out any bugs or risks:\n\n", "Code"),
            ("Debug this error", "Here is an error and the related code. Explain the root cause and give a fix:\n\n", "Code"),
            ("Write tests", "Write focused unit tests for the following code. Cover edge cases:\n\n", "Code"),
            ("Commit message", "Write a conventional commit message (subject under 72 chars, then a short body) for this diff:\n\n", "Code"),
            ("Meeting follow-up email", "Draft a short follow-up email from these meeting notes, listing decisions and owners:\n\n", "Meetings"),
            ("Extract action items", "Extract action items from the text below as a checklist with owner and deadline when mentioned:\n\n", "Meetings")
        ]
        for (title, body, category) in prompts {
            context.insert(PromptTemplate(title: title, body: body, category: category))
        }
        try? context.save()
        defaults.set(true, forKey: seededKey)
    }
}
