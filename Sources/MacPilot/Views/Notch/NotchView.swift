import SwiftData
import SwiftUI

/// The black shape that grows out of the notch, with flared top corners like the hardware notch.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = min(bottomRadius, rect.height / 2, (rect.width - 2 * t) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct NotchView: View {
    private let notch = NotchController.shared
    private let recorder = RecordingManager.shared
    private let dictation = DictationController.shared
    private let ear: CGFloat = 8

    var body: some View {
        let size = notch.shapeSize
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: ear, bottomRadius: notch.isExpanded ? 28 : min(14, size.height / 2))
                    .fill(Color.black)
                    .shadow(color: .black.opacity(notch.isExpanded ? 0.35 : 0), radius: 18, y: 8)
                if let peek = notch.peekMessage, !notch.isExpanded {
                    PeekBanner(peek: peek, notchHeight: notch.geometry.notch.height)
                        .padding(.horizontal, ear + 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                } else if notch.isExpanded {
                    ExpandedNotch(notchSize: notch.geometry.notch.size)
                        .padding(.horizontal, ear + 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else if notch.activity != .idle {
                    CompactNotch(activity: notch.activity, notchWidth: notch.geometry.notch.width, sideWidth: NotchController.compactSideWidth)
                        .frame(height: size.height)
                        .padding(.horizontal, ear)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width == 0 ? 0 : size.width + ear * 2, height: size.height)
            .animation(.spring(response: 0.38, dampingFraction: 0.8), value: size)
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.panelSize.width, height: NotchController.panelSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .tint(DS.accent)
    }
}

// MARK: - Compact

private struct CompactNotch: View {
    let activity: NotchActivity
    let notchWidth: CGFloat
    let sideWidth: CGFloat
    private let recorder = RecordingManager.shared
    private let dictation = DictationController.shared

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: sideWidth, alignment: .leading).padding(.leading, 12)
            Spacer().frame(width: max(0, notchWidth - 12))
            trailing.frame(width: sideWidth, alignment: .trailing).padding(.trailing, 12)
        }
        .foregroundStyle(.white)
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .recording(let paused):
            HStack(spacing: 5) {
                PulsingDot(color: paused ? .orange : .red, pulsing: !paused)
                Text(paused ? "Paused" : "REC").foregroundStyle(paused ? .orange : .red)
            }
        case .dictating:
            WaveformBars(level: dictation.level).frame(width: 30, height: 16)
        case .meetingSoon:
            Image(systemName: "calendar").foregroundStyle(Color.red)
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ProgressRing(progress: NotchTimers.shared.current?.progress(at: context.date) ?? 1, color: .orange)
                    .frame(width: 16, height: 16)
            }
        case .nowPlaying:
            ArtworkThumb(image: NowPlaying.shared.artwork, size: 20)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .recording:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(TranscriptSegment.format(recorder.elapsed(at: context.date)))
            }
        case .dictating:
            Text(dictation.phase == .listening ? "Listening" : "Working…").foregroundStyle(.secondary)
        case .meetingSoon(_, let start):
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(Countdown.text(to: start, end: start.addingTimeInterval(3600), now: context.date)
                    .replacingOccurrences(of: " min", with: "m"))
            }
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(TranscriptSegment.format(NotchTimers.shared.current?.remaining(at: context.date) ?? 0)).foregroundStyle(.orange)
            }
        case .nowPlaying:
            EqualizerBars(playing: NowPlaying.shared.isPlaying).frame(width: 18, height: 14)
        case .idle:
            EmptyView()
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    let pulsing: Bool
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(pulsing && on ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = true }
    }
}

// MARK: - Expanded

private struct ExpandedNotch: View {
    let notchSize: CGSize
    private let recorder = RecordingManager.shared
    private let dictation = DictationController.shared
    private let calendar = CalendarService.shared
    @Query(filter: #Predicate<TaskItem> { !$0.isCompleted }) private var openTasks: [TaskItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            mainCard
            if NotchTimers.shared.current != nil { TimerCard() }
            if NowPlaying.shared.track != nil { MediaCard() }
            if !NotchShelf.shared.items.isEmpty || NotchShelf.shared.isDropTargeted { ShelfCard() }
            quickActions
        }
        .foregroundStyle(.white)
    }

    /// Clock and date sit on either side of the camera.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.brandGradient)
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                }
                Spacer(minLength: notchSize.width)
                Text(context.date.formatted(date: .omitted, time: .shortened))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(height: max(notchSize.height, 24))
        }
    }

    @ViewBuilder
    private var mainCard: some View {
        if recorder.isActive {
            recordingCard
        } else if dictation.phase.isActive {
            dictationCard
        } else {
            meetingCard
        }
    }

    private var recordingCard: some View {
        HStack(spacing: 12) {
            PulsingDot(color: recorder.isPaused ? .orange : .red, pulsing: !recorder.isPaused)
            VStack(alignment: .leading, spacing: 3) {
                Text(recorder.current?.title ?? "Recording").font(.headline).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(TranscriptSegment.format(recorder.elapsed(at: context.date)))
                        .font(.system(.caption, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let live = recorder.liveTranscriber, let line = (live.partial.isEmpty ? live.segments.last?.text : live.partial) {
                    Text(line).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            LevelMeter(level: recorder.level).frame(width: 70, height: 6)
            NotchButton(systemImage: recorder.isPaused ? "play.fill" : "pause.fill", label: recorder.isPaused ? "Resume" : "Pause") {
                recorder.togglePause()
            }
            NotchButton(systemImage: "stop.fill", label: "Stop", tint: .red) {
                Task { await recorder.stop() }
            }
        }
        .notchCard()
    }

    private var dictationCard: some View {
        HStack(spacing: 12) {
            WaveformBars(level: dictation.level).frame(width: 40, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("Dictating · \(dictation.mode.label)").font(.headline)
                Text(dictation.partialText.isEmpty ? "Speak now" : dictation.partialText)
                    .font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(2).truncationMode(.head)
            }
            Spacer()
            NotchButton(systemImage: "xmark", label: "Cancel") { dictation.cancel() }
        }
        .notchCard()
    }

    @ViewBuilder
    private var meetingCard: some View {
        let _ = calendar.revision
        if let event = calendar.upcoming(limit: 1, withinDays: 1).first {
            let link = MeetingLink.find(in: [event.location, event.notes])
            TimelineView(.periodic(from: .now, by: 15)) { context in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 2).fill(event.calendar.color.color).frame(width: 4, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title).font(.headline).lineLimit(1)
                        Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened)) · \(Countdown.text(to: event.start, end: event.end, now: context.date))")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    if let link {
                        NotchButton(systemImage: "video.fill", label: "Join", tint: .green) {
                            NSWorkspace.shared.open(link)
                            NotchController.shared.collapse()
                        }
                    }
                    NotchButton(systemImage: "record.circle", label: "Record", tint: .red) {
                        Task { await recorder.start(kind: .meeting, title: event.title, eventID: event.id, attendees: event.attendeeNames) }
                    }
                }
            }
            .notchCard()
        } else {
            HStack(spacing: 12) {
                Image(systemName: calendar.isConnected ? "checkmark.seal.fill" : "calendar.badge.exclamationmark")
                    .foregroundStyle(calendar.isConnected ? Color.green : Color.orange).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(calendar.isConnected ? "No more meetings today" : "Calendar not connected").font(.headline)
                    Text(openTasks.isEmpty ? "No open tasks." : "\(openTasks.count) open task\(openTasks.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                NotchButton(systemImage: "checklist", label: "Tasks") { WindowManager.shared.showDashboard(section: .tasks) }
            }
            .notchCard()
        }
    }

    private var quickActions: some View {
        HStack(spacing: 0) {
            QuickNotchAction(systemImage: "sparkles", label: "Ask AI", color: DS.violet) { WindowManager.shared.toggleQuickAssistant() }
            QuickNotchAction(systemImage: "mic.fill", label: "Dictate", color: .pink) { dictation.hotKeyDown(mode: Prefs.dictationDefaultMode); dictation.hotKeyUp() }
            QuickNotchAction(systemImage: recorder.isActive ? "stop.fill" : "record.circle", label: recorder.isActive ? "Stop" : "Record", color: .red) {
                recorder.toggleMeeting()
            }
            QuickNotchAction(systemImage: "doc.on.clipboard", label: "Clipboard", color: .teal) { WindowManager.shared.toggleClipboardPanel() }
            QuickNotchAction(systemImage: "command", label: "Launcher", color: DS.indigo) { WindowManager.shared.toggleLauncher() }
            QuickNotchAction(systemImage: "square.and.pencil", label: "Note", color: .orange) { WindowManager.shared.open(.notes, action: .newNote) }
        }
    }
}

private struct NotchButton: View {
    let systemImage: String
    let label: String
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint == .white ? .white : tint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.22 : 0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct QuickNotchAction: View {
    let systemImage: String
    let label: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            NotchController.shared.collapse()
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(color.opacity(hovering ? 0.9 : 0.7).gradient))
                    .scaleEffect(hovering ? 1.08 : 1)
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(label)
    }
}

private extension View {
    func notchCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.08)))
    }
}

// MARK: - Peek, timer and media

private struct PeekBanner: View {
    let peek: NotchPeek
    let notchHeight: CGFloat

    private var color: Color {
        switch peek.tint {
        case .accent: return DS.accent
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .blue: return .blue
        }
    }

    var body: some View {
        Button {
            if let action = peek.action { NotchController.shared.perform(action) } else { NotchController.shared.dismissPeek() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: peek.systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(color.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(peek.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !peek.subtitle.isEmpty {
                        Text(peek.subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if peek.action != nil {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .foregroundStyle(.white)
            .padding(.top, notchHeight + 6)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(peek.title)
    }
}

private struct TimerCard: View {
    private let timers = NotchTimers.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let countdown = timers.current {
                HStack(spacing: 12) {
                    ProgressRing(progress: countdown.progress(at: context.date), color: .orange).frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(countdown.label).font(.headline).lineLimit(1)
                        Text("Ends \(countdown.endsAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Text(TranscriptSegment.format(countdown.remaining(at: context.date)))
                        .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                        .foregroundStyle(.orange)
                    NotchButton(systemImage: "plus", label: "Add 5 minutes") { timers.addFiveMinutes() }
                    NotchButton(systemImage: "xmark", label: "Cancel timer") { timers.cancel() }
                }
                .notchCard()
            }
        }
    }
}

/// Files parked on the notch. Drop files here; drag them out to any app.
private struct ShelfCard: View {
    private let shelf = NotchShelf.shared
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 8) {
            if shelf.items.isEmpty {
                Image(systemName: "tray.and.arrow.down.fill").font(.title3).foregroundStyle(DS.accent)
                Text("Drop files to park them here").font(.headline)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(shelf.items, id: \.self) { url in
                            ShelfFile(url: url)
                        }
                    }
                }
                Divider().frame(height: 30).overlay(.white.opacity(0.2))
                NotchButton(systemImage: "sparkles", label: "Ask AI about these files") { shelf.askAI(shelf.items) }
                NotchButton(systemImage: "dot.radiowaves.left.and.right", label: "AirDrop all") { shelf.airDrop(shelf.items) }
                NotchButton(systemImage: "xmark", label: "Clear shelf") { shelf.clear() }
            }
        }
        .frame(height: 38)
        .notchCard()
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DS.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .opacity(targeted || shelf.isDropTargeted ? 1 : 0)
        )
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in NotchShelf.shared.add([url]) }
                }
            }
            NotchShelf.shared.isDropTargeted = false
            return true
        }
    }
}

private struct ShelfFile: View {
    let url: URL
    private let shelf = NotchShelf.shared
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 26, height: 26)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 9, weight: .medium)).lineLimit(1).truncationMode(.tail)
                .frame(width: 60)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(hovering ? 0.14 : 0)))
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { shelf.open(url) }
        .help("\(url.lastPathComponent) — drag out to use it, double-click to open, right-click for more")
        .contextMenu {
            Button("Open") { shelf.open(url) }
            Button("Ask AI about it") { shelf.askAI([url]) }
            Button("AirDrop…") { shelf.airDrop([url]) }
            Button("Show in Finder") { shelf.reveal([url]) }
            Divider()
            Button("Remove from shelf") { shelf.remove(url) }
        }
    }
}

private struct MediaCard: View {
    private let media = NowPlaying.shared

    var body: some View {
        if let track = media.track {
            HStack(spacing: 12) {
                Button { media.openPlayer() } label: { ArtworkThumb(image: media.artwork, size: 38) }
                    .buttonStyle(.plain)
                    .help("Open \(track.player.rawValue)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.headline).lineLimit(1)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer()
                EqualizerBars(playing: media.isPlaying).frame(width: 18, height: 14)
                NotchButton(systemImage: "backward.fill", label: "Previous") { media.previous() }
                NotchButton(systemImage: media.isPlaying ? "pause.fill" : "play.fill", label: media.isPlaying ? "Pause" : "Play") { media.playPause() }
                NotchButton(systemImage: "forward.fill", label: "Next") { media.next() }
            }
            .notchCard()
        }
    }
}

private struct ProgressRing: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: max(0.001, min(1, 1 - progress)))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
        }
        .accessibilityHidden(true)
    }
}

private struct ArtworkThumb: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Little bouncing bars while music plays.
private struct EqualizerBars: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4) { index in
                    let phase = sin(t * (5 + Double(index) * 1.7) + Double(index))
                    Capsule()
                        .fill(Color.green)
                        .frame(width: 3, height: playing ? 4 + CGFloat((phase + 1) / 2) * 10 : 4)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityLabel(playing ? "Playing" : "Paused")
    }
}
