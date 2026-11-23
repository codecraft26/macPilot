import AVFoundation
import CoreLocation
import EventKit
import Speech
import UserNotifications
import XCTest
@testable import MacPilot

final class SetupTests: XCTestCase {
    func testStepMachineResumeSkipBack() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "setup-\(UUID().uuidString)"))
        var progress = SetupProgress()
        XCTAssertEqual(progress.current, .welcome)
        progress.complete()
        XCTAssertEqual(progress.current, .provider)
        progress.skip()
        XCTAssertEqual(progress.current, .permissions)
        XCTAssertTrue(progress.skipped.contains(.provider))
        progress.back()
        XCTAssertEqual(progress.current, .provider, "back works")
        progress.complete()
        XCTAssertFalse(progress.skipped.contains(.provider), "completing a skipped step clears the skip")
        XCTAssertEqual(progress.current, .permissions)
        progress.save(defaults)

        // Quit and relaunch: resumes at the same step.
        let resumed = SetupProgress.load(defaults)
        XCTAssertEqual(resumed.current, .permissions)
        XCTAssertEqual(resumed.resumeStep(), .permissions)
        XCTAssertEqual(resumed.completed, [.welcome, .provider])

        var first = SetupProgress()
        first.back()
        XCTAssertEqual(first.current, .welcome, "can't go back before the first step")
    }

    func testRequiredVersusOptionalCounts() {
        var progress = SetupProgress()
        XCTAssertEqual(SetupProgress.totalCount, 7)
        XCTAssertEqual(SetupProgress.requiredSteps, [.provider, .permissions, .features, .updates])
        for step in [SetupStep.welcome, .provider, .permissions, .calendar, .features] {
            progress.go(to: step)
            progress.complete()
        }
        progress.skip() // telegram (optional)
        XCTAssertFalse(progress.allRequiredDone, "updates is still required")
        XCTAssertEqual(progress.doneCount, 5)
        progress.complete() // updates
        XCTAssertTrue(progress.allRequiredDone, "optional skipped steps don't block “done”")
        XCTAssertEqual(progress.current, .done)
    }

    func testSetupVersionReshowsOnlyForNewSteps() {
        var progress = SetupProgress()
        XCTAssertTrue(progress.shouldShow(), "first launch")
        progress.current = .updates
        for step in SetupStep.allCases { progress.completed.insert(step) }
        progress.finish(version: 1)
        XCTAssertFalse(progress.shouldShow(currentVersion: 1), "finished: not shown again")
        XCTAssertTrue(progress.shouldShow(currentVersion: 2), "a newer setup version shows it again")
        // In version 2 a new step (say Telegram) was added: resume there, not at the start.
        progress.completed.remove(.telegram)
        let resume = progress.resumeStep(currentVersion: 2) { $0 == .telegram ? 2 : 1 }
        XCTAssertEqual(resume, .telegram)
        XCTAssertEqual(SetupProgress().resumeStep(), .welcome, "never finished: start where you were")
    }

    func testPermissionStatusMapping() {
        XCTAssertEqual(PermissionMapping.av(.authorized), .granted)
        XCTAssertEqual(PermissionMapping.av(.notDetermined), .needed)
        XCTAssertEqual(PermissionMapping.av(.denied), .denied)
        XCTAssertEqual(PermissionMapping.av(.restricted), .denied)
        XCTAssertEqual(PermissionMapping.speech(.authorized), .granted)
        XCTAssertEqual(PermissionMapping.speech(.denied), .denied)
        XCTAssertEqual(PermissionMapping.eventKit(.fullAccess), .granted)
        XCTAssertEqual(PermissionMapping.eventKit(.writeOnly), .needed, "write-only isn't enough to show meetings")
        XCTAssertEqual(PermissionMapping.eventKit(.notDetermined), .needed)
        XCTAssertEqual(PermissionMapping.notifications(.provisional), .granted)
        XCTAssertEqual(PermissionMapping.notifications(.denied), .denied)
        XCTAssertEqual(PermissionMapping.location(.authorizedAlways), .granted)
        XCTAssertEqual(PermissionMapping.location(.notDetermined), .needed)
        XCTAssertEqual(PermissionMapping.trusted(true), .granted)
        XCTAssertEqual(PermissionMapping.trusted(false), .needed)
        XCTAssertEqual(PermissionMapping.automation(noErr), .granted)
        XCTAssertEqual(PermissionMapping.automation(OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertEqual(PermissionMapping.automation(OSStatus(errAEEventWouldRequireUserConsent)), .needed)
        XCTAssertEqual(PermissionMapping.automation(OSStatus(procNotFound)), .unknown, "Mail not running: can't tell yet")
        XCTAssertTrue(SetupPermission.allCases.allSatisfy { $0.settingsURL.scheme == "x-apple.systempreferences" })
        XCTAssertTrue(SetupPermission.location.isOptional)
        XCTAssertFalse(SetupPermission.accessibility.isOptional)
    }

    func testProviderKeyGoesToKeychainOnly() throws {
        var written: [(String, String)] = []
        let secret = "sk-ant-api03-" + String(repeating: "Z", count: 40)
        try SetupKeyStore.save("  \(secret)\n", for: .anthropic) { written.append(($0, $1)) }
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?.0, secret, "trimmed")
        XCTAssertEqual(written.first?.1, "anthropic", "the Keychain account is the provider")
        let everything = UserDefaults.standard.dictionaryRepresentation().values.map { "\($0)" }.joined()
        XCTAssertFalse(everything.contains(secret), "never in UserDefaults")
        XCTAssertThrowsError(try SetupKeyStore.save("   ", for: .openAI) { _, _ in XCTFail("empty keys aren't written") })
    }
}
