import AppKit
import SwiftUI
import XCTest
@testable import MacPilot

final class DictationTests: XCTestCase {
    func testPromptsPerMode() {
        let email = DictationPrompt.system(mode: .email, language: "English", vocabulary: ["MacPilot", "SwiftData"])
        XCTAssertTrue(email.contains("never answer it"))
        XCTAssertTrue(email.contains("greeting"))
        XCTAssertTrue(email.contains("MacPilot, SwiftData"))
        XCTAssertTrue(DictationPrompt.system(mode: .translate, language: "Hindi", vocabulary: []).contains("into Hindi"))
        XCTAssertTrue(DictationPrompt.system(mode: .codePrompt, language: "", vocabulary: []).contains("backticks"))
        XCTAssertFalse(DictationPrompt.system(mode: .plain, language: "", vocabulary: []).contains("Spell these terms"))
        XCTAssertNil(DictationPrompt.transcriptionHint(vocabulary: []))
        XCTAssertEqual(DictationPrompt.transcriptionHint(vocabulary: ["Bedrock"]), "Vocabulary: Bedrock.")
    }

    func testFillerRemoval() {
        XCTAssertEqual(FillerRemover.clean("um so I I think we should, uh, ship it"), "So I think we should, ship it.")
        XCTAssertEqual(FillerRemover.clean("hello world?"), "Hello world?")
        XCTAssertEqual(FillerRemover.clean("Umbrella is the the plan"), "Umbrella is the plan.")
    }

    func testHoldVersusTap() {
        let t0 = Date(timeIntervalSince1970: 0)
        var hold = DictationKeyState()
        XCTAssertEqual(hold.keyDown(at: t0, pushToTalk: true), .start)
        XCTAssertEqual(hold.keyDown(at: t0.addingTimeInterval(0.1), pushToTalk: true), .none) // auto-repeat
        XCTAssertEqual(hold.keyUp(at: t0.addingTimeInterval(1.2)), .stop)
        XCTAssertEqual(hold.phase, .idle)

        var tap = DictationKeyState()
        XCTAssertEqual(tap.keyDown(at: t0, pushToTalk: true), .start)
        XCTAssertEqual(tap.keyUp(at: t0.addingTimeInterval(0.15)), .none)
        XCTAssertEqual(tap.phase, .handsFree)
        XCTAssertEqual(tap.keyDown(at: t0.addingTimeInterval(5), pushToTalk: true), .stop)
        XCTAssertEqual(tap.keyUp(at: t0.addingTimeInterval(5.1)), .none)

        var toggle = DictationKeyState()
        XCTAssertEqual(toggle.keyDown(at: t0, pushToTalk: false), .start)
        XCTAssertEqual(toggle.keyUp(at: t0.addingTimeInterval(2)), .none)
        XCTAssertEqual(toggle.keyDown(at: t0.addingTimeInterval(3), pushToTalk: false), .stop)
    }

    func testPasteboardSnapshotRestores() {
        let board = NSPasteboard(name: NSPasteboard.Name("MacPilotTests-\(UUID().uuidString)"))
        board.clearContents()
        board.setString("original", forType: .string)
        let snapshot = PasteboardSnapshot.capture(board)
        board.clearContents()
        board.setString("dictated", forType: .string)
        snapshot.restore(to: board)
        XCTAssertEqual(board.string(forType: .string), "original")
        board.releaseGlobally()
    }
}

@MainActor
final class FloatingPanelTests: XCTestCase {
    func testPanelsHaveNoWindowButtons() {
        let panel = FloatingPanel(rootView: Text("x"), size: NSSize(width: 200, height: 100), nonActivating: true)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(panel.standardWindowButton(button)?.isHidden ?? true, true)
        }
    }
}
