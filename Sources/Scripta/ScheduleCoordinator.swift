import AppKit
import Foundation

final class ScheduleCoordinator: ObservableObject {
    @Published var conflictPrompt: ScheduledRecording?

    let store: ScheduleStore
    private let recorder: MeetingRecorder
    private var activeRecordingScheduleId: UUID?
    private var conflictDismissedForId: UUID?
    private var isLaunchingSchedule = false
    private var autoStartBackoffUntil: [UUID: Date] = [:]
    private var notifiedPermissionBlockFor: Set<UUID> = []
    private var tickTask: Task<Void, Never>?

    init(recorder: MeetingRecorder, store: ScheduleStore) {
        self.recorder = recorder
        self.store = store
    }

    func start() {
        guard tickTask == nil else { return }
        reconcileStaleRecordingStatuses(now: Date())
        Task { await ScheduleNotificationService.shared.requestAuthorizationIfNeeded() }

        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick(now: Date())
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reconcile(now: Date())
                Task { @MainActor in
                    await self.retryDueSchedulesAfterActivation()
                }
            }
        }
    }

    private func retryDueSchedulesAfterActivation() async {
        guard await ScreenRecordingAccess.isReadyForScheduledCapture() else { return }
        let now = Date()
        for item in store.items where item.status == .armed || item.status == .pending {
            guard item.autoStart, now >= item.startAt, now < item.endAt else { continue }
            guard !recorder.isRecording else { return }
            autoStartBackoffUntil.removeValue(forKey: item.id)
            await beginRecording(item)
            return
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    func reconcile(now: Date = Date()) {
        store.load()
        reconcileStaleRecordingStatuses(now: now)
        tick(now: now)
    }

    func saveSchedule(_ draft: ScheduledRecording) throws {
        try store.upsert(draft)
        refreshStartNotification(for: draft)
    }

    func cancelSchedule(id: UUID) {
        detachActiveSchedule(id: id, stopRecorder: true)
        store.cancel(id: id)
        ScheduleNotificationService.shared.cancelStartReminder(for: id)
    }

    /// Stop the recorder for this schedule and mark the schedule cancelled (user ended the appointment).
    func stopScheduledRecording(id: UUID) {
        detachActiveSchedule(id: id, stopRecorder: true)
        if store.item(id: id)?.status == .recording {
            store.updateStatus(id: id, status: .cancelled)
        }
        ScheduleNotificationService.shared.cancelStartReminder(for: id)
    }

    /// Retry auto-start after permissions were granted (e.g. user returned from Settings).
    func isLiveCapture(for scheduleId: UUID) -> Bool {
        recorder.isRecording
            && (activeRecordingScheduleId == scheduleId || recorder.scheduledRecordingId == scheduleId)
    }

    func retryStartIfNeeded(id: UUID) {
        autoStartBackoffUntil.removeValue(forKey: id)
        notifiedPermissionBlockFor.remove(id)
        guard let item = store.item(id: id) else { return }
        guard item.status == .armed || item.status == .pending else { return }
        let now = Date()
        guard now >= item.startAt, now < item.endAt, item.autoStart else { return }
        guard !recorder.isRecording else { return }
        Task { @MainActor in
            await self.beginRecording(item)
        }
    }

    func acceptConflict() {
        guard let schedule = conflictPrompt else { return }
        conflictPrompt = nil
        conflictDismissedForId = schedule.id
        if recorder.isRecording {
            recorder.stopRecording()
        }
        Task { @MainActor in
            await self.waitUntilRecordingIdle()
            await self.beginRecording(schedule)
        }
    }

    func declineConflict() {
        guard let schedule = conflictPrompt else { return }
        conflictPrompt = nil
        conflictDismissedForId = schedule.id
        if Date() >= schedule.endAt {
            store.updateStatus(id: schedule.id, status: .missed)
        }
    }

    private func tick(now: Date) {
        reconcileStaleRecordingStatuses(now: now)
        handleRecorderCompletionIfNeeded()

        for item in store.items {
            switch item.status {
            case .pending, .armed:
                handleUpcoming(item, now: now)
            case .recording:
                handleActive(item, now: now)
            case .completed, .missed, .cancelled:
                continue
            }
        }
    }

    private func handleUpcoming(_ item: ScheduledRecording, now: Date) {
        if now >= item.endAt {
            store.updateStatus(id: item.id, status: .missed)
            return
        }

        let fiveMinBefore = item.startAt.addingTimeInterval(-5 * 60)
        if now >= fiveMinBefore, now < item.startAt, !item.notifiedFiveMinuteBefore {
            store.markNotifiedFiveMinute(id: item.id)
            if item.status == .pending {
                store.updateStatus(id: item.id, status: .armed)
            }
            ScheduleNotificationService.shared.notify(
                title: "Upcoming: \(item.title)",
                body: "Starts at \(Self.timeFormatter.string(from: item.startAt)).",
                identifier: "schedule-5m-\(item.id.uuidString)"
            )
        }

        guard item.autoStart, now >= item.startAt, now < item.endAt else { return }

        if recorder.isRecording {
            if conflictDismissedForId != item.id, conflictPrompt?.id != item.id {
                conflictPrompt = item
            }
            return
        }

        guard !isLaunchingSchedule, canAttemptAutoStart(item, now: now) else { return }
        Task { @MainActor in
            await self.beginRecording(item)
        }
    }

    private func canAttemptAutoStart(_ item: ScheduledRecording, now: Date) -> Bool {
        guard let until = autoStartBackoffUntil[item.id] else { return true }
        return now >= until
    }

    private func handleActive(_ item: ScheduledRecording, now: Date) {
        if activeRecordingScheduleId == item.id, item.autoStop, now >= item.endAt, recorder.isRecording {
            recorder.stopRecording()
        }
        if now >= item.endAt, activeRecordingScheduleId != item.id {
            store.updateStatus(id: item.id, status: .missed)
        }
    }

    @MainActor
    private func beginRecording(_ item: ScheduledRecording) async {
        guard !isLaunchingSchedule, !recorder.isRecording else { return }
        guard await ScreenRecordingAccess.isReadyForScheduledCapture() else {
            if Date() >= item.endAt {
                store.updateStatus(id: item.id, status: .missed)
            } else {
                store.updateStatus(id: item.id, status: .armed)
                registerAutoStartFailure(for: item, reason: .permissionsNotReady)
            }
            return
        }
        isLaunchingSchedule = true
        defer { isLaunchingSchedule = false }
        recorder.configureForScheduledRecording(item)
        NSApp.activate(ignoringOtherApps: true)
        await recorder.startRecording()
        if recorder.state == .recording {
            autoStartBackoffUntil.removeValue(forKey: item.id)
            notifiedPermissionBlockFor.remove(item.id)
            activeRecordingScheduleId = item.id
            store.updateStatus(id: item.id, status: .recording)
        } else {
            activeRecordingScheduleId = nil
            if Date() >= item.endAt {
                store.updateStatus(id: item.id, status: .missed)
            } else {
                store.updateStatus(id: item.id, status: .armed)
                registerAutoStartFailure(for: item, reason: .startFailed)
            }
        }
    }

    private enum AutoStartFailureReason {
        case permissionsNotReady
        case startFailed
    }

    @MainActor
    private func registerAutoStartFailure(for item: ScheduledRecording, reason: AutoStartFailureReason) {
        autoStartBackoffUntil[item.id] = Date().addingTimeInterval(45)
        guard !notifiedPermissionBlockFor.contains(item.id) else { return }
        notifiedPermissionBlockFor.insert(item.id)
        let body: String
        switch reason {
        case .permissionsNotReady:
            body = "Complete Permissions Setup (System Audio / mic / speech) for Scripta in /Applications, then quit & reopen or tap Retry start."
        case .startFailed:
            body = "Could not start recording. Check Screen Recording for Scripta in System Settings, then Retry start."
        }
        ScheduleNotificationService.shared.notify(
            title: "Scheduled recording blocked",
            body: body,
            identifier: "schedule-perm-\(item.id.uuidString)"
        )
    }

    /// Schedules marked recording in JSON but the app is not actually capturing (quit during permissions, etc.).
    private func reconcileStaleRecordingStatuses(now: Date) {
        for item in store.items where item.status == .recording {
            let linkedToRecorder = recorder.isRecording
                && (activeRecordingScheduleId == item.id || recorder.scheduledRecordingId == item.id)

            if linkedToRecorder {
                if activeRecordingScheduleId == nil {
                    activeRecordingScheduleId = item.id
                }
                continue
            }

            activeRecordingScheduleId = nil
            if now >= item.endAt {
                store.updateStatus(id: item.id, status: .missed)
            } else {
                store.updateStatus(id: item.id, status: .armed)
            }
        }
    }

    private func detachActiveSchedule(id: UUID, stopRecorder: Bool) {
        let matches = activeRecordingScheduleId == id
            || recorder.scheduledRecordingId == id
            || store.item(id: id)?.status == .recording
        guard matches else { return }
        if stopRecorder, recorder.isRecording {
            recorder.stopRecording()
        }
        if activeRecordingScheduleId == id {
            activeRecordingScheduleId = nil
        }
    }

    private func handleRecorderCompletionIfNeeded() {
        guard recorder.state == .completed,
              let scheduleId = activeRecordingScheduleId else { return }

        guard store.item(id: scheduleId)?.status == .recording else {
            activeRecordingScheduleId = nil
            return
        }

        let folderName = URL(fileURLWithPath: recorder.exportedFilePath).lastPathComponent
        let linked = folderName.isEmpty ? nil : folderName
        store.updateStatus(id: scheduleId, status: .completed, linkedFolder: linked)
        activeRecordingScheduleId = nil
        conflictDismissedForId = nil
    }

    private func waitUntilRecordingIdle() async {
        for _ in 0..<180 {
            switch recorder.state {
            case .idle, .completed, .failed:
                return
            case .recording, .transcribing:
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func refreshStartNotification(for item: ScheduledRecording) {
        ScheduleNotificationService.shared.cancelStartReminder(for: item.id)
        guard item.notifyIfAppInactive else { return }
        guard item.status == .pending || item.status == .armed else { return }
        guard item.startAt > Date() else { return }
        ScheduleNotificationService.shared.scheduleStartReminder(for: item)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
