import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Where /screenshot gets its picture (a mock in tests).
protocol TelegramScreenSource {
    var isScreenLocked: Bool { get }
    var hasPermission: Bool { get }
    func captureMainDisplay() async throws -> Data
}

enum ScreenshotError: LocalizedError {
    case noDisplay, encodeFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display to capture."
        case .encodeFailed: return "Couldn't encode the screenshot."
        }
    }
}

/// Main display via ScreenCaptureKit, with MacPilot's own windows left out.
struct SystemScreenSource: TelegramScreenSource {
    /// Telegram photos must be under 10 MB and 10,000 px in width + height.
    static let maxBytes = 9_000_000
    static let maxDimension = 2_560

    var isScreenLocked: Bool { Self.screenLocked() }
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true || (session["CGSSessionScreenIsLocked"] as? Int ?? 0) == 1
    }

    func captureMainDisplay() async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ScreenshotError.noDisplay
        }
        let ownID = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { $0.bundleIdentifier == ownID || $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let size = Self.fit(width: display.width * 2, height: display.height * 2, maxDimension: Self.maxDimension)
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try Self.jpeg(image)
    }

    static func fit(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxDimension, longest > 0 else { return (width, height) }
        let scale = Double(maxDimension) / Double(longest)
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }

    /// JPEG, lowering quality until it fits Telegram's photo limit.
    static func jpeg(_ image: CGImage, maxBytes: Int = maxBytes) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        for quality in [0.8, 0.65, 0.5, 0.35, 0.2] {
            if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= maxBytes { return data }
        }
        throw ScreenshotError.encodeFailed
    }
}
