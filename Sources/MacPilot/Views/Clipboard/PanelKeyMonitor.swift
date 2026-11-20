import AppKit
import SwiftUI

/// Keys the Raycast-style panels react to while their window is key.
enum PanelKey: Equatable, Sendable {
    case up, down, enter, tab, escape
    case commandDelete
    case command(Character)
    case commandDigit(Int)

    struct Event: Equatable, Sendable {
        var key: PanelKey
        var shift = false
        var command = false
    }

    static func from(_ event: NSEvent) -> Event? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        switch event.keyCode {
        case 126: return Event(key: .up, shift: shift, command: command)
        case 125: return Event(key: .down, shift: shift, command: command)
        case 36, 76: return Event(key: .enter, shift: shift, command: command)
        case 48: return Event(key: .tab, shift: shift, command: command)
        case 53: return Event(key: .escape)
        case 51 where command: return Event(key: .commandDelete, command: true)
        default: break
        }
        guard command, let character = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
        if let digit = character.wholeNumberValue, (1...9).contains(digit) {
            return Event(key: .commandDigit(digit), shift: shift, command: true)
        }
        return Event(key: .command(character), shift: shift, command: true)
    }
}

/// Installs a local key monitor for one panel window. Returning true from the handler swallows the key.
@MainActor
final class PanelKeyMonitor {
    private var monitor: Any?

    func install(window: @escaping @MainActor () -> NSWindow?, handler: @escaping @MainActor (PanelKey.Event) -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let key = PanelKey.from(event) else { return event }
            let windowNumber = event.windowNumber
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let target = window(), target.windowNumber == windowNumber, target.isKeyWindow else { return false }
                return handler(key)
            }
            return swallow ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.caption2.monospaced().weight(.semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
