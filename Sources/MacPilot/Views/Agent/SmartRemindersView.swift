import CoreLocation
import SwiftData
import SwiftUI

/// Agent → Reminders: create in plain words, confirm, and manage context reminders and saved places.
struct SmartRemindersView: View {
    @Query(sort: \SmartReminder.createdAt, order: .reverse) private var reminders: [SmartReminder]
    @State private var input = ""
    @State private var draft: ReminderDraft?
    @State private var parsing = false
    @State private var error: String?
    @State private var syncToReminders = false
    @State private var showingPlaces = false
    private let engine = ReminderEngine.shared

    var body: some View {
        VStack(spacing: 0) {
            composer.padding(DS.Space.m)
            Divider()
            if reminders.isEmpty {
                EmptyStateView(systemImage: "bell.badge", title: "No smart reminders yet",
                               message: "Try “remind me to check PR reviews when I open Xcode”, “… when I join the Office Wi-Fi”, “… when I get home” or “… 10 minutes before my next meeting”.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(reminders) { reminder in row(reminder) }
                }
            }
        }
        .sheet(isPresented: $showingPlaces) { PlacesSheet() }
        .onAppear {
            if let pending = AgentTabState.shared.pendingReminder {
                AgentTabState.shared.pendingReminder = nil
                input = pending
                parse()
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                TextField("Remind me… e.g. “to check PR reviews when I open Xcode”", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(parse)
                Button(action: parse) { if parsing { ProgressView().controlSize(.small) } else { Text("Next") } }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || parsing)
                Button { showingPlaces = true } label: { Label("Places", systemImage: "mappin.and.ellipse") }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let draft {
                HStack(alignment: .top) {
                    Image(systemName: draft.trigger.systemImage).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.confirmation).font(.headline)
                        if case .wifiJoined = draft.trigger, engine.wifiNeedsLocation { locationNote }
                        if case .wifiLeft = draft.trigger, engine.wifiNeedsLocation { locationNote }
                        if case .arrive(let place) = draft.trigger, !engine.places.contains(where: { $0.name.caseInsensitiveCompare(place) == .orderedSame }) {
                            Text("Define “\(place)” under Places (by this Mac's location or by a Wi-Fi network).").font(.caption).foregroundStyle(.orange)
                        }
                        Toggle("Also add to Apple Reminders (via Tasks sync)", isOn: $syncToReminders).font(.caption)
                    }
                    Spacer()
                    Button("Cancel") { self.draft = nil }
                    Button("Save reminder") {
                        engine.add(draft, source: input, syncToReminders: syncToReminders)
                        self.draft = nil
                        input = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(DS.Space.s)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var locationNote: some View {
        HStack {
            Text("macOS only shares Wi-Fi names with apps that have Location access. Without it, Wi-Fi reminders can't fire.")
                .font(.caption).foregroundStyle(.orange)
            Button("Allow Location…") { engine.requestLocationPermission() }.font(.caption)
        }
    }

    private func parse() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        parsing = true
        error = nil
        Task {
            let words = text.lowercased().hasPrefix("remind") ? text : "remind me " + text
            draft = await ReminderInput.parse(words)
            parsing = false
            if draft == nil {
                error = AgentSettings.load().localOnly
                    ? "I couldn't read that without a model (local-only mode). Try “… when I open Xcode”, “… at 5pm”, “… when I get home”."
                    : "I couldn't work out when to remind you. Try “… when I open Xcode” or “… before my next meeting”."
            }
        }
    }

    private func row(_ reminder: SmartReminder) -> some View {
        HStack {
            Image(systemName: reminder.trigger.systemImage).foregroundStyle(reminder.isDone ? Color.secondary : Color.blue).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.text).strikethrough(reminder.isDone)
                Text(details(reminder)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(get: { reminder.repeatMode }, set: { reminder.repeatMode = $0; try? reminder.modelContext?.save() })) {
                ForEach(ReminderRepeat.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 110).disabled(!reminder.trigger.isContext)
            Toggle("", isOn: Binding(get: { reminder.enabled }, set: { reminder.enabled = $0; try? reminder.modelContext?.save() }))
                .labelsHidden().toggleStyle(.switch)
            Menu {
                if !reminder.isDone { Button("Done") { engine.done(reminder) } } else { Button("Reopen") { reminder.isDone = false; reminder.firedCount = 0 } }
                Button("Snooze 10 min") { engine.snooze(reminder, minutes: 10) }
                Button("Delete", role: .destructive) { engine.delete(reminder) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func details(_ reminder: SmartReminder) -> String {
        var parts = [reminder.trigger.summary]
        let conditions = reminder.conditions.summary
        if !conditions.isEmpty { parts.append(conditions) }
        if reminder.trigger.isContext { parts.append(reminder.repeatMode == .everyTime ? "every time, ≥\(reminder.cooldownMinutes) min apart" : "once") }
        if let last = reminder.lastFired { parts.append("last \(last.formatted(date: .abbreviated, time: .shortened))") }
        if let snoozed = reminder.snoozedUntil, snoozed > Date() { parts.append("snoozed until \(snoozed.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: " · ")
    }
}

/// Saved places (Home, Work…) by location or by Wi-Fi network. Stored only on this Mac.
private struct PlacesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Home"
    @State private var ssid = ""
    private let engine = ReminderEngine.shared

    var body: some View {
        let _ = engine.revision
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Places").font(.title2.bold())
            Text("Arrive/leave reminders use these. A Mac's location is coarse (Wi-Fi based; a Mac mini rarely moves), so a Wi-Fi network is often the better signal. Places and Wi-Fi names never leave this Mac and are never sent to an AI model.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(engine.places) { place in
                HStack {
                    Image(systemName: place.ssid == nil ? "location" : "wifi")
                    Text(place.name).bold()
                    Text(place.ssid.map { "Wi-Fi “\($0)”" } ?? String(format: "%.3f, %.3f (±%.0f m)", place.latitude ?? 0, place.longitude ?? 0, place.radius))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { engine.places = engine.places.filter { $0.id != place.id } }
                }
            }
            Divider()
            TextField("Name (Home, Work, Gym…)", text: $name)
            HStack {
                Button("Use this Mac's current location") { engine.saveCurrentLocation(as: name) }
                    .disabled(name.isEmpty)
                Text(engine.locationStatus == .denied ? "Location access is off (System Settings → Privacy & Security → Location Services)." : "")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                TextField("…or a Wi-Fi network name", text: $ssid)
                if let current = engine.currentSSID { Button("Use “\(current)”") { ssid = current } }
                Button("Save") {
                    var places = engine.places.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
                    places.append(SavedPlace(name: name, ssid: ssid))
                    engine.places = places
                    ssid = ""
                }
                .disabled(name.isEmpty || ssid.isEmpty)
            }
            if engine.wifiNeedsLocation {
                HStack {
                    Text("Wi-Fi names need Location access on this macOS version.").font(.caption).foregroundStyle(.orange)
                    Button("Allow Location…") { engine.requestLocationPermission() }.font(.caption)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(DS.Space.l)
        .frame(width: 560)
    }
}
