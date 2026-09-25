import SwiftUI

struct SchedulePanel: View {
    @ObservedObject var coordinator: ScheduleCoordinator
    var onDismiss: () -> Void

    @State private var showEditor = false
    @State private var editingItem: ScheduledRecording?
    @State private var editorError: String?

    private enum Theme {
        static let bg = Color(red: 0.071, green: 0.075, blue: 0.090)
        static let surface = Color(red: 0.118, green: 0.122, blue: 0.137)
        static let border = Color.white.opacity(0.10)
        static let accent = Color(red: 0.35, green: 0.60, blue: 1.0)
        static let textPrimary = Color(red: 0.94, green: 0.94, blue: 0.96)
        static let textSecondary = Color(red: 0.65, green: 0.67, blue: 0.72)
        static let textMuted = Color(red: 0.48, green: 0.50, blue: 0.55)
    }

    private var upcoming: [ScheduledRecording] {
        coordinator.store.upcomingItems()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.border)
            if upcoming.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(upcoming) { item in
                        ScheduleRow(
                            item: item,
                            isLiveCapture: coordinator.isLiveCapture(for: item.id)
                        ) {
                            editingItem = item
                            showEditor = true
                        } onCancel: {
                            coordinator.cancelSchedule(id: item.id)
                        } onStop: {
                            coordinator.stopScheduledRecording(id: item.id)
                        } onRetry: {
                            coordinator.retryStartIfNeeded(id: item.id)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.bg)
        .frame(minWidth: 480, minHeight: 360)
        .sheet(isPresented: $showEditor) {
            ScheduleEditorSheet(
                existing: editingItem,
                defaultLanguage: UserDefaults.standard.string(forKey: "Scripta.recognitionLanguage") ?? "en-US",
                onSave: { draft in
                    do {
                        try coordinator.saveSchedule(draft)
                        editorError = nil
                        showEditor = false
                        editingItem = nil
                    } catch {
                        editorError = error.localizedDescription
                    }
                },
                onCancel: {
                    showEditor = false
                    editingItem = nil
                    editorError = nil
                },
                externalError: editorError
            )
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
            Text("Scheduled Recordings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                editingItem = nil
                showEditor = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("New schedule")
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "calendar")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textMuted)
            Text("No upcoming schedules")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Scripta will start and stop recording at the times you set.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Add schedule") {
                editingItem = nil
                showEditor = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}

private struct ScheduleRow: View {
    let item: ScheduledRecording
    var isLiveCapture: Bool
    var onEdit: () -> Void
    var onCancel: () -> Void
    var onStop: () -> Void
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(Self.windowText(item))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.65))
                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .textCase(.uppercase)
            }
            Spacer()
            if isLiveCapture {
                Button("Stop recording", role: .destructive, action: onStop)
                    .font(.system(size: 11))
            } else if shouldOfferRetry {
                Button("Retry start", action: onRetry)
                    .font(.system(size: 11))
                Button("Cancel", role: .destructive, action: onCancel)
                    .font(.system(size: 11))
            } else if item.isEditable {
                Button("Edit", action: onEdit)
                    .font(.system(size: 11))
                Button("Cancel", role: .destructive, action: onCancel)
                    .font(.system(size: 11))
            } else if item.canCancel {
                Button("Cancel", role: .destructive, action: onCancel)
                    .font(.system(size: 11))
            }
        }
        .padding(.vertical, 6)
    }

    private var shouldOfferRetry: Bool {
        let now = Date()
        guard !isLiveCapture, item.autoStart, now >= item.startAt, now < item.endAt else { return false }
        return item.status == .armed || item.status == .recording
    }

    private var statusLabel: String {
        if isLiveCapture { return "Recording now" }
        if shouldOfferRetry { return "Waiting to start" }
        return item.status.rawValue
    }

    private var statusColor: Color {
        if isLiveCapture { return Color.red.opacity(0.85) }
        if shouldOfferRetry { return Color.orange.opacity(0.9) }
        return Color.blue.opacity(0.9)
    }

    private static func windowText(_ item: ScheduledRecording) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let start = f.string(from: item.startAt)
        f.dateStyle = .none
        let end = f.string(from: item.endAt)
        return "\(start) – \(end)"
    }
}

private struct ScheduleEditorSheet: View {
    var existing: ScheduledRecording?
    var defaultLanguage: String
    var onSave: (ScheduledRecording) -> Void
    var onCancel: () -> Void
    var externalError: String?

    @State private var title = ""
    @State private var startAt = Date().addingTimeInterval(3600)
    @State private var endAt = Date().addingTimeInterval(5400)
    @State private var useDuration = false
    @State private var durationMinutes = 30
    @State private var languageCode: String
    @State private var notifyIfInactive = true

    init(
        existing: ScheduledRecording?,
        defaultLanguage: String,
        onSave: @escaping (ScheduledRecording) -> Void,
        onCancel: @escaping () -> Void,
        externalError: String?
    ) {
        self.existing = existing
        self.defaultLanguage = defaultLanguage
        self.onSave = onSave
        self.onCancel = onCancel
        self.externalError = externalError
        _languageCode = State(initialValue: existing?.languageCode ?? defaultLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New schedule" : "Edit schedule")
                .font(.headline)
            TextField("Meeting name", text: $title)
            DatePicker("Start", selection: $startAt)
            Toggle("Set duration instead of end time", isOn: $useDuration)
            if useDuration {
                Stepper("Duration: \(durationMinutes) min", value: $durationMinutes, in: 5...480, step: 5)
                    .onChange(of: durationMinutes) { _, _ in syncEndFromDuration() }
                    .onChange(of: startAt) { _, _ in syncEndFromDuration() }
            } else {
                DatePicker("End", selection: $endAt)
            }
            Picker("Language", selection: $languageCode) {
                ForEach(MeetingRecorder.supportedRecognitionLanguages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            Toggle("Notify if app is not open at start time", isOn: $notifyIfInactive)
            if let externalError {
                Text(externalError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { loadExisting() }
    }

    private func loadExisting() {
        if let existing {
            title = existing.title
            startAt = existing.startAt
            endAt = existing.endAt
            let mins = max(5, Int(existing.duration / 60))
            durationMinutes = mins
            useDuration = false
            notifyIfInactive = existing.notifyIfAppInactive
            languageCode = existing.languageCode ?? defaultLanguage
        } else {
            syncEndFromDuration()
        }
    }

    private func syncEndFromDuration() {
        endAt = startAt.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }

    private func save() {
        let resolvedEnd = useDuration
            ? startAt.addingTimeInterval(TimeInterval(durationMinutes * 60))
            : endAt
        let record = ScheduledRecording(
            id: existing?.id ?? UUID(),
            title: title,
            startAt: startAt,
            endAt: resolvedEnd,
            languageCode: languageCode,
            autoStart: true,
            autoStop: true,
            notifyIfAppInactive: notifyIfInactive,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            status: existing?.status == .armed ? .armed : .pending,
            linkedSessionFolderId: existing?.linkedSessionFolderId,
            notifiedFiveMinuteBefore: existing?.notifiedFiveMinuteBefore ?? false
        )
        onSave(record)
    }
}
