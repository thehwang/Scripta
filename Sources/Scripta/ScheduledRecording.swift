import Foundation

enum ScheduledStatus: String, Codable, CaseIterable {
    case pending
    case armed
    case recording
    case completed
    case missed
    case cancelled
}

struct ScheduledRecording: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var startAt: Date
    var endAt: Date
    var languageCode: String?
    var autoStart: Bool
    var autoStop: Bool
    var notifyIfAppInactive: Bool
    var createdAt: Date
    var updatedAt: Date
    var status: ScheduledStatus
    var linkedSessionFolderId: String?
    var notifiedFiveMinuteBefore: Bool

    init(
        id: UUID = UUID(),
        title: String,
        startAt: Date,
        endAt: Date,
        languageCode: String? = nil,
        autoStart: Bool = true,
        autoStop: Bool = true,
        notifyIfAppInactive: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: ScheduledStatus = .pending,
        linkedSessionFolderId: String? = nil,
        notifiedFiveMinuteBefore: Bool = false
    ) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.languageCode = languageCode
        self.autoStart = autoStart
        self.autoStop = autoStop
        self.notifyIfAppInactive = notifyIfAppInactive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.linkedSessionFolderId = linkedSessionFolderId
        self.notifiedFiveMinuteBefore = notifiedFiveMinuteBefore
    }

    var duration: TimeInterval {
        max(0, endAt.timeIntervalSince(startAt))
    }

    func overlaps(with otherStart: Date, otherEnd: Date) -> Bool {
        startAt < otherEnd && endAt > otherStart
    }

    var isEditable: Bool {
        status == .pending || status == .armed
    }

    var canCancel: Bool {
        status == .pending || status == .armed || status == .recording
    }

    var isActivelyRecording: Bool {
        status == .recording
    }
}

struct ScheduleFileEnvelope: Codable {
    var version: Int
    var items: [ScheduledRecording]
}

enum ScheduleStoreError: LocalizedError {
    case overlappingSchedule
    case invalidWindow
    case emptyTitle
    case notEditableWhileRecording

    var errorDescription: String? {
        switch self {
        case .overlappingSchedule:
            return "This time overlaps another scheduled recording."
        case .invalidWindow:
            return "End time must be after start time."
        case .emptyTitle:
            return "Meeting name is required."
        case .notEditableWhileRecording:
            return "Stop or cancel this schedule before editing."
        }
    }
}
