import Foundation

enum LocalWhisper {
    static let installedExecutables = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]

    static func transcribe(_ file: URL, speaker: String, offset: Double) async throws -> [TranscriptSegment] {
        let defaults = UserDefaults.standard
        let configured = path(defaults.string(forKey: PrefKey.whisperExecutable) ?? "")
        let model = path(defaults.string(forKey: PrefKey.whisperModel) ?? "")
        let files = FileManager.default
        let executable = configured.isEmpty ? installedExecutables.first(where: files.isExecutableFile(atPath:)) : configured
        guard let executable, executable.hasPrefix("/"), files.isExecutableFile(atPath: executable) else {
            throw TranscribeError.configuration("Install whisper-cli and select the executable in Settings → Routing.")
        }
        var isDirectory: ObjCBool = false
        guard model.hasPrefix("/"), files.fileExists(atPath: model, isDirectory: &isDirectory),
              !isDirectory.boolValue, files.isReadableFile(atPath: model) else {
            throw TranscribeError.configuration("Select a readable whisper.cpp model file in Settings → Routing.")
        }

        let directory = files.temporaryDirectory.appendingPathComponent("MacPilot-Whisper-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }

        let wave = directory.appendingPathComponent("audio.wav")
        let input: URL
        if await AudioTools.convertToWave(file, output: wave) {
            input = wave
        } else if ["flac", "mp3", "ogg", "wav"].contains(file.pathExtension.lowercased()) {
            input = file
        } else {
            throw TranscriptionError.exportFailed("macOS could not convert this file to 16 kHz WAV.")
        }

        try Task.checkCancellation()
        let output = directory.appendingPathComponent("transcript")
        let result = await Shell.run(executable, [
            "-m", model, "-f", input.path, "-l", "auto", "-oj", "-of", output.path
        ], timeout: 14_400)
        guard result.ok else {
            let reason = result.timedOut ? "The local transcription timed out." : "Check the executable and model selected in Settings → Routing."
            throw TranscribeError.configuration("whisper-cli failed. \(reason)")
        }
        guard let data = try? Data(contentsOf: output.appendingPathExtension("json")) else {
            throw TranscribeError.configuration("whisper-cli did not produce a transcript. Check that your executable supports JSON output.")
        }
        return try segments(data, speaker: speaker, offset: offset)
    }

    private static func path(_ value: String) -> String {
        (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    static func segments(_ data: Data, speaker: String, offset: Double) throws -> [TranscriptSegment] {
        struct Output: Decodable {
            struct Line: Decodable {
                struct Offsets: Decodable { let from: Double; let to: Double }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Line]
        }
        let output = try JSONDecoder().decode(Output.self, from: data)
        return output.transcription.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, line.offsets.from >= 0, line.offsets.to >= line.offsets.from else { return nil }
            return TranscriptSegment(start: offset + line.offsets.from / 1000, end: offset + line.offsets.to / 1000,
                                     speaker: speaker, text: text)
        }
    }
}
