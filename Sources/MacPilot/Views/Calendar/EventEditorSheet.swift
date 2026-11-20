import SwiftUI

/// Create or edit an event. Nothing touches the calendar until the user presses Save.
struct EventEditorSheet: View {
    @State var draft: EventDraft
    var notice: String?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var isSaving = false
    private let calendar = CalendarService.shared

    private static let alarmChoices: [Int?] = [nil, 0, 5, 10, 15, 30, 60, 1440]

    private var conflicts: [CalendarEvent] {
        guard !draft.isAllDay else { return [] }
        return calendar.conflicts(start: draft.start, end: draft.end, excluding: draft.eventID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if let notice {
                    Label(notice, systemImage: "sparkles").font(.callout).foregroundStyle(.secondary)
                }
                TextField("Title", text: $draft.title)
                Toggle("All day", isOn: $draft.isAllDay)
                DatePicker("Starts", selection: $draft.start, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    .onChange(of: draft.start) { old, new in
                        // Keep the duration when the start moves.
                        draft.end = new.addingTimeInterval(max(300, draft.end.timeIntervalSince(old)))
                    }
                DatePicker("Ends", selection: $draft.end, in: draft.start..., displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                Picker("Calendar", selection: Binding(
                    get: { draft.calendarID ?? calendar.defaultCalendarID ?? "" },
                    set: { draft.calendarID = $0 }
                )) {
                    ForEach(calendar.writableCalendars) { item in
                        Text(item.source == .google ? "\(item.title) (Google\(item.account.isEmpty ? "" : " · \(item.account)"))" : item.title).tag(item.id)
                    }
                }
                Picker("Alert", selection: $draft.alarmMinutes) {
                    ForEach(Self.alarmChoices, id: \.self) { minutes in
                        Text(Self.alarmLabel(minutes)).tag(minutes)
                    }
                }
                TextField("Location", text: $draft.location)
                Section("Notes") {
                    TextEditor(text: $draft.notes).frame(minHeight: 60)
                }
                if !conflicts.isEmpty {
                    Section {
                        ForEach(conflicts) { event in
                            Label("\(event.title) · \(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Conflicts with")
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            .formStyle(.grouped)

            HStack {
                if draft.eventID != nil {
                    Button("Delete Event", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isSaving { ProgressView().controlSize(.small) }
                Button(draft.eventID == nil ? "Add to Calendar" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(calendar.writableCalendars.isEmpty || isSaving)
            }
            .padding(16)
        }
        .frame(width: 480, height: 600)
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete) {
            Button("Delete Event", role: .destructive) { deleteEvent() }
        } message: {
            Text("It is removed from \(calendar.event(withID: draft.eventID ?? "")?.calendar.title ?? "your calendar") on every device that syncs it.")
        }
    }

    static func alarmLabel(_ minutes: Int?) -> String {
        switch minutes {
        case nil: return "None"
        case 0?: return "At time of event"
        case 1440?: return "1 day before"
        case let value?: return value >= 60 ? "\(value / 60) hour before" : "\(value) minutes before"
        }
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            do {
                try await calendar.save(draft)
                dismiss()
            } catch {
                self.error = AIError.describe(error)
            }
            isSaving = false
        }
    }

    private func deleteEvent() {
        guard let id = draft.eventID, let event = calendar.event(withID: id) else { return }
        isSaving = true
        Task {
            do {
                try await calendar.delete(event)
                dismiss()
            } catch {
                self.error = AIError.describe(error)
            }
            isSaving = false
        }
    }
}

/// Wrapper so a draft can drive `.sheet(item:)`.
struct EventEditorRequest: Identifiable {
    let id = UUID()
    var draft: EventDraft
    var notice: String?
}
