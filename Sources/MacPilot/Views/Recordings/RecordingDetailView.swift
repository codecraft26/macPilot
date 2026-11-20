import AVFoundation
import AVKit
import AppKit
import Observation
import SwiftData
import SwiftUI

/// Plays the microphone and system audio tracks together, aligned by the recorded offset.
@Observable
@MainActor
final class RecordingPlayer {
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var isLoaded = false
    private var observer: Any?

    private(set) var hasVideo = false

    func load(tracks: [(url: URL, offset: Double)], video: (url: URL, offset: Double)? = nil) async {
        guard let composition = await RecordingMedia.composition(audio: tracks, video: video) else { return }
        hasVideo = !composition.tracks(withMediaType: .video).isEmpty
        let player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                self.isPlaying = (self.player?.rate ?? 0) > 0
            }
        }
        self.player = player
        isLoaded = true
    }

    func togglePlay() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.play() }
        isPlaying = player.rate > 0
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
        if player.rate == 0 { player.play() }
        isPlaying = true
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case summary = "Summary", transcript = "Transcript", prep = "Prep notes"
    var id: String { rawValue }
}

struct RecordingDetailView: View {
    @Bindable var recording: Recording
    var onDelete: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @State private var tab: DetailTab = .summary
    @State private var player = RecordingPlayer()
    @State private var confirmDelete = false
    @State private var flash: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            banners
            Picker("View", selection: $tab) {
                ForEach(tabs) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            switch tab {
            case .summary: SummaryTab(recording: recording, flash: $flash)
            case .transcript: TranscriptTab(recording: recording, player: player)
            case .prep: PrepTab(recording: recording)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: recording.audioURLs.map(\.path).joined() + (recording.screenURL?.path ?? "")) {
            player.stop()
            await player.load(tracks: RecordingMedia.audioTracks(recording),
                              video: recording.screenURL.map { (url: $0, offset: recording.screenOffset) })
        }
        .onAppear {
            if !recording.hasAnalysis && !recording.segments.isEmpty { tab = .transcript }
        }
        .onDisappear { player.stop() }
        .confirmationDialog("Delete \(recording.title)?", isPresented: $confirmDelete) {
            Button("Delete recording and audio", role: .destructive, action: onDelete)
        } message: {
            Text("The audio files, transcript and summary are removed. This cannot be undone.")
        }
    }

    private func exportVideo() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Exporter.safeFileName(recording.title) + ".mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let audio = RecordingMedia.audioTracks(recording)
        let video = recording.screenURL.map { (url: $0, offset: recording.screenOffset) }
        flash = "Exporting video…"
        Task {
            do {
                try await RecordingMedia.exportVideo(audio: audio, video: video, to: url)
                flash = "Video saved to \(url.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                flash = nil
                recording.errorMessage = "Video export failed: \(error.localizedDescription)"
            }
        }
    }

    private var tabs: [DetailTab] {
        recording.kind == .meeting ? DetailTab.allCases : [.summary, .transcript]
    }

    private var isBusy: Bool { recording.status.isBusy }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: $recording.title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .onSubmit { try? context.save() }
                StatusBadge(status: recording.status)
            }
            HStack(spacing: 8) {
                Label(recording.kind.label, systemImage: recording.kind.systemImage)
                Text(recording.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text(TranscriptSegment.format(recording.duration))
                if !recording.attendees.isEmpty {
                    Label(recording.attendees, systemImage: "person.2").lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(recording.segments.isEmpty ? "Transcribe" : "Re-transcribe") {
                    RecordingProcessor.transcribe(recording)
                }
                .disabled(isBusy || recording.audioURLs.isEmpty)
                Button(recording.hasAnalysis ? "Re-analyze" : "Analyze") {
                    RecordingProcessor.analyze(recording)
                }
                .disabled(isBusy || recording.segments.isEmpty)
                Button("Save as note") {
                    let note = RecordingActions.saveAsNote(recording, context: context)
                    appState.pendingAction = .openNote(note.uid)
                    appState.selectedSection = .notes
                }
                .disabled(recording.segments.isEmpty && !recording.hasAnalysis)
                Button("Ask AI") { RecordingActions.startChat(about: recording, context: context) }
                    .disabled(recording.segments.isEmpty)
                Menu("Export") {
                    Button("Markdown…") {
                        Exporter.save(text: TranscriptExport.markdown(for: recording), suggestedName: Exporter.safeFileName(recording.title) + ".md")
                    }
                    Button("Plain text…") {
                        Exporter.save(text: recording.transcriptText, suggestedName: Exporter.safeFileName(recording.title) + ".txt", fileExtension: "txt")
                    }
                    if recording.screenURL != nil {
                        Button("Screen video with audio (MP4)…") { exportVideo() }
                    }
                    Button("Subtitles (SRT)…") {
                        Exporter.save(text: TranscriptExport.srt(recording.segments), suggestedName: Exporter.safeFileName(recording.title) + ".srt", fileExtension: "srt")
                    }
                    .disabled(recording.segments.isEmpty)
                }
                .fixedSize()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(recording.audioURLs.isEmpty ? [recording.folderURL] : recording.audioURLs)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show audio files in Finder")
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .disabled(recording.status == .recording)
                    .help("Delete recording")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if isBusy && recording.status != .recording {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(recording.status == .transcribing
                     ? "Transcribing with \(Prefs.transcriptionProvider.displayName)…"
                     : "Analyzing with \(Prefs.analysisProvider.displayName)…")
                    .font(.callout)
            }
        }
        if let error = recording.errorMessage {
            Label(error, systemImage: "exclamationmark.octagon")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            // Common mix-up: AWS keys are saved but transcription still points at OpenAI.
            if error.contains("OpenAI"), Prefs.transcriptionProvider == .openAI,
               BedrockConfig.authMethod == .accessKeys, BedrockConfig.isConfigured {
                Button("Use Amazon Transcribe and try again") {
                    UserDefaults.standard.set(TranscriptionProviderID.amazonTranscribe.rawValue, forKey: PrefKey.transcriptionProvider)
                    RecordingProcessor.process(recording)
                }
                .controlSize(.small)
            }
        }
        if let notice = recording.notice {
            Label(notice, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let flash {
            Label(flash, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Summary

private struct SummaryTab: View {
    @Bindable var recording: Recording
    @Binding var flash: String?
    @Environment(\.modelContext) private var context

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if !recording.hasAnalysis {
                    Text(recording.segments.isEmpty
                         ? "Transcribe this recording first, then MacPilot can summarize it, list decisions and action items, and draft a follow-up email."
                         : "No summary yet. Press Analyze to create one with \(Prefs.analysisProvider.displayName).")
                        .foregroundStyle(.secondary)
                } else {
                    section("Summary") {
                        Text(recording.summary).textSelection(.enabled)
                    }
                    list("Decisions", recording.decisions, icon: "checkmark.seal")
                    if !recording.actionItems.isEmpty {
                        section("Action items") {
                            ForEach(recording.actionItems) { item in
                                HStack(alignment: .top) {
                                    Image(systemName: "circle")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.task)
                                        HStack {
                                            if let owner = item.owner { Label(owner, systemImage: "person") }
                                            if let due = item.due { Label(due, systemImage: "calendar") }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Add task") {
                                        RecordingActions.addTask(item, from: recording, context: context)
                                        flash = "Added “\(item.task)” to Tasks."
                                    }
                                    .controlSize(.small)
                                }
                            }
                            Button("Add all as tasks") {
                                let added = RecordingActions.addMissingTasks(from: recording, context: context)
                                flash = added == 0 ? "All action items are already tasks." : "Added \(added) tasks (category Meeting)."
                            }
                        }
                    }
                    list("Deadlines", recording.deadlines, icon: "calendar.badge.clock")
                    list("Open questions", recording.openQuestions, icon: "questionmark.circle")
                    if !recording.followUpEmail.isEmpty {
                        section("Follow-up email") {
                            Text(recording.followUpEmail)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                            HStack {
                                Button("Open in Mail") {
                                    flash = RecordingActions.openFollowUpInMail(recording)
                                        ? "Draft opened in Mail — review and send it yourself." : "Couldn't open Mail; the email is copied instead."
                                    if flash?.hasPrefix("Couldn't") == true { Clipboard.copy(recording.followUpEmail) }
                                }
                                Button("Copy email") {
                                    Clipboard.copy(recording.followUpEmail)
                                    flash = "Follow-up email copied."
                                }
                            }
                        }
                        section("Follow up in one click") {
                            Text("Opens the email as a Mail draft to the attendees (you send it), adds the action items as tasks (they sync to Reminders), and opens a follow-up meeting for next week to confirm.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button {
                                    let mailed = RecordingActions.openFollowUpInMail(recording)
                                    let added = RecordingActions.addMissingTasks(from: recording, context: context)
                                    flash = [mailed ? "Mail draft opened" : "Couldn't open Mail", "\(added) task\(added == 1 ? "" : "s") added"].joined(separator: " · ")
                                } label: { Label("Do the follow-up", systemImage: "paperplane") }
                                .buttonStyle(.borderedProminent)
                                Button("Schedule next meeting…") {
                                    WindowManager.shared.open(.calendar, action: .quickAddEvent("Follow-up: \(recording.title) next week at the same time"))
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: DS.Space.s)
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String], icon: String) -> some View {
        if !items.isEmpty {
            section(title) {
                ForEach(items, id: \.self) { item in
                    Label(item, systemImage: icon).textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Transcript editor

private struct TranscriptTab: View {
    @Bindable var recording: Recording
    let player: RecordingPlayer
    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var renaming: String?
    @State private var newName = ""

    private var segments: [TranscriptSegment] { recording.segments }

    private var currentID: UUID? {
        guard player.isPlaying else { return nil }
        return segments.last { $0.start <= player.currentTime + 0.1 }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if player.hasVideo, let avPlayer = player.player {
                VideoPlayer(player: avPlayer)
                    .frame(minHeight: 220, idealHeight: 300, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                    .accessibilityLabel("Screen recording")
            }
            HStack(spacing: 10) {
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(!player.isLoaded)
                Text(player.isLoaded ? TranscriptSegment.format(player.currentTime) : "No audio")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                TextField("Search transcript", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                if !recording.speakers.isEmpty {
                    Menu("Speakers") {
                        ForEach(recording.speakers, id: \.self) { speaker in
                            Button("Rename “\(speaker)”…") {
                                newName = speaker
                                renaming = speaker
                            }
                        }
                    }
                    .fixedSize()
                }
            }

            if segments.isEmpty {
                Text(recording.status == .transcribing ? "Transcribing…" : "No transcript yet. Press Transcribe above.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            if search.isEmpty || segment.text.localizedCaseInsensitiveContains(search) || segment.speaker.localizedCaseInsensitiveContains(search) {
                                SegmentRow(
                                    segment: segment,
                                    isCurrent: segment.id == currentID,
                                    text: binding(for: index),
                                    onSeek: { player.seek(to: segment.start) }
                                )
                                .id(segment.id)
                            }
                        }
                    }
                    .onChange(of: currentID) { _, id in
                        if let id, search.isEmpty { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let old = renaming { recording.renameSpeaker(old, to: newName) }
                try? context.save()
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Every line by “\(renaming ?? "")” is updated.")
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { index < recording.segments.count ? recording.segments[index].text : "" },
            set: { newValue in
                var all = recording.segments
                guard index < all.count else { return }
                all[index].text = newValue
                recording.segments = all
            }
        )
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let isCurrent: Bool
    @Binding var text: String
    var onSeek: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onSeek) {
                Text(segment.timestamp).font(.caption.monospacedDigit())
            }
            .buttonStyle(.link)
            .help("Play from here")
            Text(segment.speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(segment.speaker == "Me" ? Color.accentColor : .purple)
                .frame(width: 70, alignment: .leading)
                .lineLimit(1)
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

// MARK: - Prep notes

private struct PrepTab: View {
    @Bindable var recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agenda, questions and context. Included when the meeting is analyzed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $recording.prepNotes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
    }
}

/// Builds one timeline from a recording's audio tracks and optional screen video.
enum RecordingMedia {
    @MainActor
    static func audioTracks(_ recording: Recording) -> [(url: URL, offset: Double)] {
        var tracks: [(url: URL, offset: Double)] = []
        if let mic = recording.micURL, recording.audioURLs.contains(mic) { tracks.append((mic, 0)) }
        if let system = recording.systemURL, recording.audioURLs.contains(system) { tracks.append((system, recording.systemAudioOffset)) }
        return tracks
    }

    static func composition(audio: [(url: URL, offset: Double)], video: (url: URL, offset: Double)?) async -> AVMutableComposition? {
        let composition = AVMutableComposition()
        for (url, offset) in audio {
            await insert(.audio, from: url, at: offset, into: composition)
        }
        if let video {
            await insert(.video, from: video.url, at: video.offset, into: composition)
        }
        return composition.tracks.isEmpty ? nil : composition
    }

    private static func insert(_ type: AVMediaType, from url: URL, at offset: Double, into composition: AVMutableComposition) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: type).first,
              let duration = try? await asset.load(.duration),
              let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        try? target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: CMTime(seconds: offset, preferredTimescale: 600))
        if type == .video, let transform = try? await track.load(.preferredTransform) { target.preferredTransform = transform }
    }

    /// One MP4 with the screen and all audio mixed together.
    static func exportVideo(audio: [(url: URL, offset: Double)], video: (url: URL, offset: Double)?, to output: URL) async throws {
        guard let composition = await composition(audio: audio, video: video),
              let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw AVError(.unknown)
        }
        // Mix microphone and system audio into the single soundtrack most players expect.
        let mix = AVMutableAudioMix()
        mix.inputParameters = composition.tracks(withMediaType: .audio).map { AVMutableAudioMixInputParameters(track: $0) }
        session.audioMix = mix
        try? FileManager.default.removeItem(at: output)
        if #available(macOS 15, *) {
            try await session.export(to: output, as: .mp4)
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            await session.export()
            if session.status != .completed { throw session.error ?? AVError(.unknown) }
        }
    }
}
