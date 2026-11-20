import Foundation

/// What the user asked the buddy to do, parsed locally (no AI needed for these).
enum PilotCommand: Equatable {
    case addTask(title: String, due: Date?)
    case startMeeting
    case stopRecording
    case voiceNote
    case newNote(String)
    case today
    case timer(seconds: Int, label: String)
    case open(AppSection)
    case dictate
    case hide
    case cancel
    /// Anything else: answered by the AI.
    case chat(String)

    static func parse(_ raw: String, now: Date = Date()) -> PilotCommand {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for prefix in ["hey pilot", "hi pilot", "ok pilot", "okay pilot", "pilot"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            break
        }
        let lower = text.lowercased()
        func rest(after pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: match.numberOfRanges - 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }

        if lower.isEmpty || ["cancel", "never mind", "nevermind", "stop", "be quiet", "shut up", "nothing"].contains(lower) { return .cancel }
        if ["hide", "go away", "hide yourself", "hide the buddy"].contains(lower) { return .hide }

        if let task = rest(after: #"^(?:please\s+)?(?:add|create|make|new)\s+(?:a\s+)?(?:new\s+)?(?:task|to-?do|reminder)(?:\s+to)?(?:\s*:)?\s+(.+)$"#)
            ?? rest(after: #"^(?:please\s+)?remind me to\s+(.+)$"#) {
            let (title, due) = splitDate(task, now: now)
            return .addTask(title: title, due: due)
        }
        if lower.range(of: #"^(stop|end|finish)\s+(the\s+)?(meeting\s+)?(recording|voice note)"#, options: .regularExpression) != nil { return .stopRecording }
        if lower.range(of: #"(record|take|start)\s+(a\s+)?voice\s+note"#, options: .regularExpression) != nil { return .voiceNote }
        if lower.range(of: #"^(start|begin)\s+(a\s+|the\s+)?(meeting\s+)?recording|^record\s+(this|the|a|my)\s+(meeting|call)"#, options: .regularExpression) != nil {
            return .startMeeting
        }
        if lower.range(of: #"what('s| is) next|what('s| is) on (my )?(calendar|agenda|schedule)|what do i have (today|next)|how('s| is) my day|my day|today'?s (schedule|plan|agenda)|brief me"#, options: .regularExpression) != nil {
            return .today
        }
        if lower.contains("timer") {
            var normalized = lower
            for phrase in ["set a timer for", "start a timer for", "set timer for", "a timer for", "set a timer", "start a timer"] {
                normalized = normalized.replacingOccurrences(of: phrase, with: "timer")
            }
            if !normalized.hasPrefix("timer") { normalized = "timer " + normalized.replacingOccurrences(of: "timer", with: "") }
            if let parsed = TimerParser.parse(normalized) { return .timer(seconds: parsed.seconds, label: parsed.label) }
        }
        if let note = rest(after: #"^(?:new|take|make|create|write)\s+(?:a\s+)?note(?:\s+(?:that|saying))?(?:\s*:)?\s*(.*)$"#) ?? rest(after: #"^note that\s+(.+)$"#) {
            return .newNote(note)
        }
        if lower.range(of: #"^(start\s+)?dictat(e|ion)|^type (what i say|for me)"#, options: .regularExpression) != nil { return .dictate }
        if let target = rest(after: #"^(?:open|show|go to)\s+(?:my\s+|the\s+)?(.+)$"#)?.lowercased() {
            let map: [(String, AppSection)] = [("note", .notes), ("task", .tasks), ("reminder", .tasks), ("calendar", .calendar),
                                               ("meeting", .calendar), ("clipboard", .clipboard), ("setting", .settings),
                                               ("dashboard", .dashboard), ("home", .dashboard), ("assistant", .assistant), ("chat", .assistant),
                                               ("file", .tools), ("pdf", .tools), ("developer", .developer), ("automation", .automations),
                                               ("recording", .voice), ("voice", .voice)]
            if let section = map.first(where: { target.contains($0.0) })?.1 { return .open(section) }
        }
        return .chat(text)
    }

    /// "call mom tomorrow at 5pm" → ("Call mom", tomorrow 17:00).
    static func splitDate(_ text: String, now: Date = Date()) -> (String, Date?) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return (capitalized(text), nil) }
        var title = text
        title.removeSubrange(range)
        title = title.replacingOccurrences(of: #"\s+(by|on|at|for|due)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (capitalized(title.isEmpty ? text : title), match.date)
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
