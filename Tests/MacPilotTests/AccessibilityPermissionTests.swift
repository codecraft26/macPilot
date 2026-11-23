import XCTest
@testable import MacPilot

final class AccessibilityPermissionTests: XCTestCase {
    func testPaneNameFollowsMacOSVersion() {
        XCTAssertEqual(ComputerPermissions.accessibilityPaneName(majorVersion: 15), "Accessibility")
        XCTAssertEqual(ComputerPermissions.accessibilityPaneName(majorVersion: 26), "Accessibility")
        XCTAssertEqual(ComputerPermissions.accessibilityPaneName(majorVersion: 27), "Device Control and Data Access")
        XCTAssertEqual(ComputerPermissions.accessibilityPath(majorVersion: 27),
                       "System Settings → Privacy & Security → Device Control and Data Access")
        XCTAssertEqual(ComputerPermissions.accessibilitySettings.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                       "the same reveal key opens the renamed list")
    }

    func testHelpPointsAwayFromTheAssistiveAppsList() {
        XCTAssertTrue(ComputerPermissions.accessibilityHelp.contains("Privacy & Security"))
        XCTAssertTrue(ComputerPermissions.accessibilityHelp.contains("reopen MacPilot"))
    }

    /// This Mac's System Settings: the list behind Privacy_Accessibility is titled as accessibilityPaneName() says.
    func testMatchesSystemSettingsStrings() throws {
        let table = "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Resources/Localizable.loctable"
        guard let data = FileManager.default.contents(atPath: table),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let english = plist["en"] as? [String: Any], let title = english["ACCESSIBILITY"] as? String else {
            throw XCTSkip("System Settings strings not readable on this Mac")
        }
        XCTAssertEqual(title, ComputerPermissions.accessibilityPaneName())
    }
}
