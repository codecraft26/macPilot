import SwiftUI

/// Voice & Transcription: record voice notes or meetings, import audio files, and browse every recording.
struct VoiceView: View {
    @State private var showingImporter = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordingControlBar(onImport: { showingImporter = true })
                .padding(16)
            if let importError {
                Label(importError, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            RecordingsBrowser(
                kinds: Set(RecordingKind.allCases),
                emptyMessage: "No recordings yet.\nRecord a voice note or meeting, or import an audio file (MP3, WAV, M4A, FLAC, OGG)."
            )
        }
        .navigationTitle("Voice & Transcription")
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: RecordingManager.importableTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                importError = nil
                Task {
                    for url in urls {
                        await RecordingManager.shared.importAudio(from: url)
                    }
                    importError = RecordingManager.shared.errorMessage
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }
}
