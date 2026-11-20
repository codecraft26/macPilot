import AppKit
import Foundation
import Observation

/// "timer 25m", "timer 1h30m tea", "25 min timer", "timer 90s".
enum TimerParser {
    static func parse(_ input: String) -> (seconds: Int, label: String)? {
        let text = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("timer ") || text.hasSuffix(" timer") || text.hasPrefix("set timer") else { return nil }
        let body = text.replacingOccurrences(of: "set timer", with: "").replacingOccurrences(of: "timer", with: "")
            .replacingOccurrences(of: " for ", with: " ")
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes|s|sec|secs|second|seconds)(?![a-z])"#) else { return nil }
        var total = 0.0
        var consumed: [Range<String.Index>] = []
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let numberRange = Range(match.range(at: 1), in: body), let unitRange = Range(match.range(at: 2), in: body),
                  let value = Double(body[numberRange]), let whole = Range(match.range, in: body) else { continue }
            switch body[unitRange].first {
            case "h": total += value * 3600
            case "m": total += value * 60
            default: total += value
            }
            consumed.append(whole)
        }
        if total == 0, let number = Double(body.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") {
            total = number * 60 // "timer 10" means minutes
            consumed.append(body.range(of: String(body.trimmingCharacters(in: .whitespaces).split(separator: " ").first!))!)
        }
        guard total >= 1, total <= 24 * 3600 else { return nil }
        var label = body
        for range in consumed.sorted(by: { $0.lowerBound > $1.lowerBound }) { label.removeSubrange(range) }
        label = label.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (Int(total.rounded()), label.isEmpty ? "" : label.prefix(1).uppercased() + label.dropFirst())
    }

    static func describe(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 && h == 0 { parts.append("\(s) s") }
        return parts.joined(separator: " ")
    }
}

/// One running countdown shown in the notch, with a chime and a system notification at the end.
@Observable
@MainActor
final class NotchTimers {
    static let shared = NotchTimers()

    struct Countdown: Equatable {
        var label: String
        var duration: TimeInterval
        var endsAt: Date

        func remaining(at date: Date = Date()) -> TimeInterval { max(0, endsAt.timeIntervalSince(date)) }
        func progress(at date: Date = Date()) -> Double { duration > 0 ? 1 - remaining(at: date) / duration : 1 }
    }

    private(set) var current: Countdown?
    private var finishTask: Task<Void, Never>?
    private let notificationID = "macpilot-notch-timer"

    func start(seconds: Int, label: String) {
        let countdown = Countdown(label: label.isEmpty ? "Timer" : label, duration: TimeInterval(seconds), endsAt: Date().addingTimeInterval(TimeInterval(seconds)))
        current = countdown
        schedule(countdown)
        NotchController.shared.peek(NotchPeek(systemImage: "timer", tint: .orange, title: "\(countdown.label) started",
                                               subtitle: TimerParser.describe(seconds)))
    }

    func addFiveMinutes() {
        guard var countdown = current else { return }
        countdown.endsAt = countdown.endsAt.addingTimeInterval(300)
        countdown.duration += 300
        current = countdown
        schedule(countdown)
    }

    func cancel() {
        finishTask?.cancel()
        current = nil
        NotificationService.cancel(id: notificationID)
    }

    private func schedule(_ countdown: Countdown) {
        finishTask?.cancel()
        // A system notification too, in case the Mac is locked or MacPilot is hidden.
        NotificationService.alert(id: notificationID, heading: "\(countdown.label) is done", body: "Your MacPilot timer finished.",
                                  after: countdown.remaining())
        finishTask = Task {
            try? await Task.sleep(for: .seconds(countdown.remaining()))
            guard !Task.isCancelled, current == countdown else { return }
            current = nil
            NSSound(named: NSSound.Name("Glass"))?.play()
            NotchController.shared.peek(NotchPeek(systemImage: "bell.fill", tint: .orange, title: "\(countdown.label) is done",
                                                   subtitle: TimerParser.describe(Int(countdown.duration)), duration: 8))
        }
    }
}
