import SwiftUI

/// Start/pause/stop controls with elapsed time and a level meter. Shown in Voice and Calendar & Meetings.
struct RecordingControlBar: View {
    var allowVoiceNote = true
    var onImport: (() -> Void)?
    private let manager = RecordingManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manager.isActive {
                activeBar
            } else {
                idleBar
            }
            if let notice = manager.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = manager.errorMessage {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(manager.isActive ? Color.red.opacity(0.6) : Color.secondary.opacity(0.15)))
    }

    private var idleBar: some View {
        HStack(spacing: 10) {
            Button {
                manager.toggleMeeting()
            } label: {
                Label("Record meeting", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Microphone + system audio (⌥R)")
            if allowVoiceNote {
                Button {
                    Task {
                        await manager.start(kind: .voiceNote, title: "Voice note \(Date().formatted(date: .abbreviated, time: .shortened))")
                    }
                } label: {
                    Label("Voice note", systemImage: "mic")
                }
            }
            if let onImport {
                Button(action: onImport) {
                    Label("Import audio…", systemImage: "square.and.arrow.down")
                }
            }
            Spacer()
            Text("Transcripts are created after you stop. Live transcription is not available yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var activeBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(manager.isPaused ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.current?.title ?? "Recording").font(.headline).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text("\(manager.isPaused ? "Paused" : "Recording") · \(TranscriptSegment.format(manager.elapsed(at: context.date)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            LevelMeter(level: manager.level)
                .frame(width: 120, height: 8)
            Spacer()
            Button {
                manager.togglePause()
            } label: {
                Label(manager.isPaused ? "Resume" : "Pause", systemImage: manager.isPaused ? "play.fill" : "pause.fill")
            }
            .disabled(manager.state == .stopping || manager.state == .starting)
            Button {
                Task { await manager.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(manager.state == .stopping || manager.state == .starting)
        }
    }
}

struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(level > 0.85 ? Color.red : Color.green)
                    .frame(width: proxy.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .accessibilityLabel("Input level")
    }
}
