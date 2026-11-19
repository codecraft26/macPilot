import SwiftUI

/// What can be done to an event from the calendar views.
@MainActor
struct EventActions {
    var edit: (CalendarEvent) -> Void
    var record: (CalendarEvent) -> Void
    var prep: (CalendarEvent) -> Void
    var delete: (CalendarEvent) -> Void

    @ViewBuilder
    func menu(for event: CalendarEvent) -> some View {
        Button("Edit…") { edit(event) }
        Button("Prep notes") { prep(event) }
        Button("Record meeting") { record(event) }
            .disabled(RecordingManager.shared.isActive)
        if event.isEditable {
            Divider()
            Button("Delete…", role: .destructive) { delete(event) }
        }
    }
}

/// Day and week views: an hour grid with events placed by time and a red line at the current time.
struct TimeGrid: View {
    let days: [Date]
    let events: [CalendarEvent]
    let conflicts: Set<String>
    let actions: EventActions
    var onDayTap: ((Date) -> Void)?

    private let hourHeight: CGFloat = 52
    private let gutter: CGFloat = 54
    private var cal: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 0) {
            if days.count > 1 { dayHeader.fixedSize(horizontal: false, vertical: true) }
            allDayRow.fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geometry in
                        let columnWidth = max(40, (geometry.size.width - gutter) / CGFloat(days.count))
                        ZStack(alignment: .topLeading) {
                            hourLines(width: geometry.size.width)
                            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                                dayColumn(day, x: gutter + CGFloat(index) * columnWidth, width: columnWidth)
                            }
                            nowLine(columnWidth: columnWidth)
                        }
                    }
                    .frame(height: hourHeight * 24)
                    .overlay(alignment: .topLeading) {
                        // Scroll anchors for each hour.
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Color.clear.frame(height: hourHeight).id(hour)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                .onAppear {
                    let hour = days.contains(where: cal.isDateInToday) ? max(0, cal.component(.hour, from: Date()) - 2) : 8
                    proxy.scrollTo(hour, anchor: .top)
                }
            }
        }
    }

    // MARK: Header rows

    private var dayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter)
            ForEach(days, id: \.self) { day in
                let today = cal.isDateInToday(day)
                Button { onDayTap?(day) } label: {
                    HStack(spacing: 6) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(today ? .red : .secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(today ? .white : .primary)
                            .frame(minWidth: 28, minHeight: 28)
                            .background(Circle().fill(today ? Color.red : .clear))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(day.formatted(date: .complete, time: .omitted))")
            }
        }
    }

    @ViewBuilder
    private var allDayRow: some View {
        let allDay = events.filter(\.isAllDay)
        if !allDay.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(.caption2).foregroundStyle(.secondary).frame(width: gutter - 6, alignment: .trailing).padding(.trailing, 6)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 2) {
                        ForEach(allDay.filter { $0.start <= day.addingTimeInterval(1) && $0.end > day }, id: \.id) { event in
                            Text(event.title)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 4).fill(event.calendar.color.color.opacity(0.25)))
                                .onTapGesture { actions.edit(event) }
                                .contextMenu { actions.menu(for: event) }
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Grid

    private func hourLines(width: CGFloat) -> some View {
        ForEach(0..<24, id: \.self) { hour in
            let y = CGFloat(hour) * hourHeight
            ZStack(alignment: .topLeading) {
                Rectangle().fill(DS.hairline).frame(width: width - gutter, height: 1).offset(x: gutter, y: y)
                if hour > 0 {
                    Text(label(for: hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: gutter - 8, alignment: .trailing)
                        .offset(y: y - 7)
                }
            }
        }
    }

    private func label(for hour: Int) -> String {
        let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    private func dayColumn(_ day: Date, x: CGFloat, width: CGFloat) -> some View {
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let timed = events.filter { !$0.isAllDay && $0.start < dayEnd && $0.end > dayStart }
        let layout = Self.layout(timed)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(cal.isDateInToday(day) && days.count > 1 ? DS.accent.opacity(0.04) : Color.clear)
                .frame(width: width, height: hourHeight * 24)
                .overlay(alignment: .leading) { Rectangle().fill(DS.hairline).frame(width: 1) }
            ForEach(timed, id: \.id) { event in
                let start = max(event.start, dayStart)
                let end = min(event.end, dayEnd)
                let top = CGFloat(start.timeIntervalSince(dayStart) / 3600) * hourHeight
                let height = max(20, CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight - 2)
                let slot = layout[event.id] ?? (lane: 0, count: 1)
                let laneWidth = (width - 6) / CGFloat(slot.count)
                EventBlock(event: event, isConflict: conflicts.contains(event.id), compact: height < 36)
                    .frame(width: laneWidth - 2, height: height)
                    .offset(x: 3 + CGFloat(slot.lane) * laneWidth, y: top + 1)
                    .onTapGesture { actions.edit(event) }
                    .contextMenu { actions.menu(for: event) }
            }
        }
        .frame(width: width, height: hourHeight * 24, alignment: .topLeading)
        .offset(x: x)
    }

    @ViewBuilder
    private func nowLine(columnWidth: CGFloat) -> some View {
        if let index = days.firstIndex(where: cal.isDateInToday) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let minutes = context.date.timeIntervalSince(cal.startOfDay(for: context.date)) / 60
                let y = CGFloat(minutes / 60) * hourHeight
                let x = gutter + CGFloat(index) * columnWidth
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.red).frame(width: columnWidth, height: 1.5)
                    Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: -4)
                }
                .offset(x: x, y: y - 0.75)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    /// Places overlapping events side by side. Events are grouped into clusters that overlap
    /// (directly or through each other); each cluster gets as many lanes as it needs.
    static func layout(_ events: [CalendarEvent]) -> [String: (lane: Int, count: Int)] {
        let sorted = events.sorted { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }
        var result: [String: (lane: Int, count: Int)] = [:]
        var cluster: [(id: String, lane: Int)] = []
        var laneEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            for item in cluster { result[item.id] = (item.lane, max(1, laneEnds.count)) }
            cluster = []
            laneEnds = []
        }

        for event in sorted {
            if event.start >= clusterEnd { flush() }
            let lane: Int
            if let free = laneEnds.firstIndex(where: { $0 <= event.start }) {
                laneEnds[free] = event.end
                lane = free
            } else {
                laneEnds.append(event.end)
                lane = laneEnds.count - 1
            }
            cluster.append((event.id, lane))
            clusterEnd = max(clusterEnd, event.end)
        }
        flush()
        return result
    }
}

private struct EventBlock: View {
    let event: CalendarEvent
    let isConflict: Bool
    let compact: Bool
    @State private var hovering = false

    var body: some View {
        let color = event.calendar.color.color
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    if event.source == .google { GoogleBadge() }
                    Text(event.title).font(.caption.weight(.semibold)).lineLimit(compact ? 1 : 2)
                }
                if !compact {
                    Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !event.location.isEmpty {
                        Text(event.location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(color.opacity(hovering ? 0.32 : 0.2))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isConflict ? Color.orange : .clear, lineWidth: 1.5))
        .onHover { hovering = $0 }
        .help(isConflict ? "\(event.title) overlaps another event" : event.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(event.start.formatted(date: .omitted, time: .shortened)) to \(event.end.formatted(date: .omitted, time: .shortened))\(isConflict ? ", conflict" : "")")
    }
}
