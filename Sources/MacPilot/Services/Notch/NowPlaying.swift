import AppKit
import Foundation
import Observation

/// What Music or Spotify is playing, from the notifications both apps broadcast (no permission needed).
/// Controls and artwork use AppleScript, so macOS asks once to let MacPilot control that app.
@Observable
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    enum Player: String {
        case music = "Music", spotify = "Spotify"
        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var player: Player
    }

    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    private var observers: [NSObjectProtocol] = []
    private var artworkFor: String?

    private init() {}

    #if DEBUG
    func setPreview(_ track: Track?, playing: Bool, artwork: NSImage?) {
        self.track = track
        isPlaying = playing
        self.artwork = artwork
    }
    #endif

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { note in
            let info = NowPlaying.strings(note.userInfo)
            MainActor.assumeIsolated { NowPlaying.shared.update(info, player: .music) }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { note in
            let info = NowPlaying.strings(note.userInfo)
            MainActor.assumeIsolated { NowPlaying.shared.update(info, player: .spotify) }
        })
        // Forget the track when the player quits.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if let current = NowPlaying.shared.track, current.player.bundleID == bundleID { NowPlaying.shared.clear() }
            }
        })
    }

    nonisolated static func strings(_ info: [AnyHashable: Any]?) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in info ?? [:] {
            if let key = key as? String { result[key] = "\(value)" }
        }
        return result
    }

    /// Both apps send "Player State" = Playing / Paused / Stopped plus Name, Artist and Album.
    func update(_ info: [String: String], player: Player) {
        let state = info["Player State"] ?? ""
        if state == "Stopped" {
            if track?.player == player { clear() }
            return
        }
        let title = info["Name"] ?? track?.title ?? ""
        guard !title.isEmpty else { return }
        let next = Track(title: title, artist: info["Artist"] ?? "", album: info["Album"] ?? "", player: player)
        if next != track {
            track = next
            artwork = nil
            loadArtwork(for: next, trackID: info["Track ID"])
        }
        isPlaying = state == "Playing"
    }

    private func clear() {
        track = nil
        isPlaying = false
        artwork = nil
    }

    // MARK: Controls

    func playPause() { run("playpause") }
    func next() { run("next track") }
    func previous() { run("previous track") }

    func openPlayer() {
        guard let track, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: track.player.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func run(_ command: String) {
        guard let player = track?.player else { return }
        let source = "tell application \"\(player.rawValue)\" to \(command)"
        Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
        if command == "playpause" { isPlaying.toggle() }
    }

    private func loadArtwork(for track: Track, trackID: String?) {
        let key = "\(track.player.rawValue)|\(track.title)|\(track.artist)"
        artworkFor = key
        let script: String
        switch track.player {
        case .spotify:
            script = "tell application \"Spotify\" to get artwork url of current track"
        case .music:
            script = "tell application \"Music\" to get raw data of artwork 1 of current track"
        }
        Task.detached {
            var error: NSDictionary?
            guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error) else { return }
            var image: NSImage?
            if track.player == .music {
                image = NSImage(data: result.data)
            } else if let string = result.stringValue, let url = URL(string: string),
                      let (data, _) = try? await URLSession.shared.data(from: url) {
                image = NSImage(data: data)
            }
            let loaded = image
            await MainActor.run {
                if NowPlaying.shared.artworkFor == key { NowPlaying.shared.artwork = loaded }
            }
        }
    }
}
