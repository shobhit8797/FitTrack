import SwiftUI

// Supplement & medication reminders (Settings → Reminders). Users add the things
// they take and when; each enabled reminder becomes repeating local
// notifications (see NotificationService). Definitions persist in Firestore so
// they sync across devices and survive reinstall.
struct RemindersView: View {
    @Environment(Repository.self) private var repo
    @Environment(NotificationService.self) private var notifications

    @State private var reminders: [SupplementReminder] = []
    @State private var loaded = false
    @State private var editing: SupplementReminder?
    @State private var showEditor = false
    @State private var error: String?

    var body: some View {
        Form {
            if notifications.isDenied {
                permissionSection
            }

            if !loaded {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if reminders.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(reminders) { reminder in
                        Button { beginEdit(reminder) } label: { row(reminder) }
                            .buttonStyle(.plain)
                    }
                    .onDelete(perform: delete)
                } footer: {
                    Text("Reminders fire as notifications even when the app is closed. Toggle one off to pause it without deleting it.")
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.caption)
                }
            }
        }
        .tint(Theme.accentTeal)
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Haptics.tap()
                    beginAdd()
                } label: {
                    Label("Add reminder", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            ReminderEditView(reminder: editing) { saved in
                await save(saved)
            }
        }
        .task {
            await notifications.refreshAuthorizationStatus()
            do {
                for try await streamed in repo.remindersStream() {
                    reminders = streamed
                    loaded = true
                }
            } catch {
                loaded = true
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Sections

    private var permissionSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications are off").font(.subheadline.weight(.semibold))
                    Text("Turn them on in the Settings app to get your reminders.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "pills.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.accentTeal.gradient)
                Text("No reminders yet")
                    .font(.headline)
                Text("Add the supplements and medications you take, and we'll remind you at the right times.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Haptics.tap()
                    beginAdd()
                } label: {
                    Label("Add a reminder", systemImage: "plus")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentTeal)
                .padding(.top, Theme.Spacing.xs)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.m)
        }
    }

    private func row(_ reminder: SupplementReminder) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: reminder.kind.icon)
                .font(.title3)
                .foregroundStyle(reminder.enabled ? AnyShapeStyle(Theme.accentTeal) : AnyShapeStyle(Color.secondary))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.name)
                    .font(.headline)
                    .foregroundStyle(reminder.enabled ? .primary : .secondary)
                Text(reminder.scheduleSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { reminder.enabled },
                set: { toggle(reminder, to: $0) }
            ))
            .labelsHidden()
            .tint(Theme.accentTeal)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func beginAdd() {
        editing = nil
        showEditor = true
    }

    private func beginEdit(_ reminder: SupplementReminder) {
        editing = reminder
        showEditor = true
    }

    private func toggle(_ reminder: SupplementReminder, to on: Bool) {
        Haptics.selection()
        var updated = reminder
        updated.enabled = on
        Task {
            if on { await ensurePermission() }
            do { try await repo.updateReminder(updated) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func save(_ reminder: SupplementReminder) async {
        error = nil
        await ensurePermission()
        do {
            if reminders.contains(where: { $0.id == reminder.id }) {
                try await repo.updateReminder(reminder)
            } else {
                try await repo.addReminder(reminder)
            }
            Haptics.success()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        Haptics.warning()
        let ids = offsets.map { reminders[$0].id }
        Task {
            for id in ids {
                try? await repo.deleteReminder(id)
            }
        }
    }

    /// Prompt for permission the first time it matters (adding/enabling), so the
    /// system alert appears in context rather than on a cold launch. Provisional
    /// (quiet, granted app-wide for the gym clock) still upgrades to the full
    /// prompt here — reminders should sound, not slip silently into the center.
    private func ensurePermission() async {
        let status = notifications.authorizationStatus
        if status == .notDetermined || status == .provisional {
            await notifications.requestAuthorization()
        }
    }
}

// MARK: - Editor

/// Add or edit a single reminder. `reminder == nil` means "new". Calls `onSave`
/// with the finished record; the caller persists it.
private struct ReminderEditView: View {
    let reminder: SupplementReminder?
    let onSave: (SupplementReminder) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var dosage: String
    @State private var kind: ReminderKind
    @State private var times: [ReminderTime]
    @State private var weekdays: Set<Int>
    @State private var everyDay: Bool
    @State private var enabled: Bool
    @State private var saving = false

    init(reminder: SupplementReminder?, onSave: @escaping (SupplementReminder) async -> Void) {
        self.reminder = reminder
        self.onSave = onSave
        _name = State(initialValue: reminder?.name ?? "")
        _dosage = State(initialValue: reminder?.dosage ?? "")
        _kind = State(initialValue: reminder?.kind ?? .supplement)
        // Default a brand-new reminder to a sensible single 9:00 AM time.
        _times = State(initialValue: reminder?.times.sorted() ?? [ReminderTime(hour: 9, minute: 0)])
        _weekdays = State(initialValue: Set(reminder?.weekdays ?? []))
        _everyDay = State(initialValue: reminder?.isEveryDay ?? true)
        _enabled = State(initialValue: reminder?.enabled ?? true)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !times.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Vitamin D, Metformin)", text: $name)
                    TextField("Dose (optional, e.g. 1 tablet)", text: $dosage)
                    Picker("Type", selection: $kind) {
                        ForEach(ReminderKind.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                    }
                }

                Section("Times") {
                    ForEach(times.indices, id: \.self) { i in
                        DatePicker(
                            "Time \(i + 1)",
                            selection: timeBinding(i),
                            displayedComponents: .hourAndMinute
                        )
                    }
                    .onDelete { offsets in
                        times.remove(atOffsets: offsets)
                    }
                    Button {
                        Haptics.tap()
                        times.append(ReminderTime(hour: 12, minute: 0))
                    } label: {
                        Label("Add time", systemImage: "plus.circle")
                    }
                }

                Section {
                    Toggle("Every day", isOn: $everyDay.animation(.snappy))
                        .tint(Theme.accentTeal)
                    if !everyDay {
                        WeekdayPicker(selected: $weekdays)
                            .padding(.vertical, Theme.Spacing.xs)
                    }
                } header: {
                    Text("Repeat")
                } footer: {
                    if !everyDay && weekdays.isEmpty {
                        Text("Pick at least one day, or turn on Every day.")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Toggle("Enabled", isOn: $enabled).tint(Theme.accentTeal)
                }
            }
            .tint(Theme.accentTeal)
            .navigationTitle(reminder == nil ? "New reminder" : "Edit reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(!canSave || saving || (!everyDay && weekdays.isEmpty))
                }
            }
        }
    }

    /// Bridges a `ReminderTime` at index `i` to the `Date` a `DatePicker` wants,
    /// keeping only the hour/minute.
    private func timeBinding(_ i: Int) -> Binding<Date> {
        Binding(
            get: {
                var comps = DateComponents()
                comps.hour = times[i].hour
                comps.minute = times[i].minute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                times[i] = ReminderTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
            }
        )
    }

    private func save() async {
        saving = true
        defer { saving = false }
        // De-dupe + sort times; normalize weekdays (empty == every day).
        let uniqueTimes = Array(Set(times)).sorted()
        let result = SupplementReminder(
            id: reminder?.id ?? "",
            name: trimmedName,
            dosage: dosage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            kind: kind,
            times: uniqueTimes,
            weekdays: everyDay ? [] : weekdays.sorted(),
            enabled: enabled,
            createdAt: reminder?.createdAt ?? Date()
        )
        await onSave(result)
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
