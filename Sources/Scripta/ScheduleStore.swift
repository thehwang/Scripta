import Foundation

final class ScheduleStore: ObservableObject {
    @Published private(set) var items: [ScheduledRecording] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("Scripta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("schedules.json")

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? decoder.decode(ScheduleFileEnvelope.self, from: data) else {
            items = []
            return
        }
        items = envelope.items.sorted { $0.startAt < $1.startAt }
    }

    private func persist() {
        let envelope = ScheduleFileEnvelope(version: 1, items: items)
        guard let data = try? encoder.encode(envelope) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func upcomingItems(now: Date = Date()) -> [ScheduledRecording] {
        items.filter { $0.status == .pending || $0.status == .armed || $0.status == .recording }
            .filter { $0.endAt > now || $0.status == .recording }
            .sorted { $0.startAt < $1.startAt }
    }

    func hasOverlap(start: Date, end: Date, excluding id: UUID?) -> Bool {
        items.contains { item in
            guard item.id != id else { return false }
            guard item.status != .cancelled && item.status != .completed && item.status != .missed else {
                return false
            }
            return item.overlaps(with: start, otherEnd: end)
        }
    }

    func upsert(_ draft: ScheduledRecording) throws {
        if let existing = items.first(where: { $0.id == draft.id }),
           existing.status == .recording {
            throw ScheduleStoreError.notEditableWhileRecording
        }
        let trimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScheduleStoreError.emptyTitle }
        guard draft.endAt > draft.startAt else { throw ScheduleStoreError.invalidWindow }
        guard !hasOverlap(start: draft.startAt, end: draft.endAt, excluding: draft.id) else {
            throw ScheduleStoreError.overlappingSchedule
        }

        var record = draft
        record.title = trimmed
        record.updatedAt = Date()
        if let idx = items.firstIndex(where: { $0.id == record.id }) {
            items[idx] = record
        } else {
            items.append(record)
        }
        items.sort { $0.startAt < $1.startAt }
        persist()
    }

    func updateStatus(id: UUID, status: ScheduledStatus, linkedFolder: String? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = status
        items[idx].updatedAt = Date()
        if let linkedFolder {
            items[idx].linkedSessionFolderId = linkedFolder
        }
        persist()
    }

    func markNotifiedFiveMinute(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].notifiedFiveMinuteBefore = true
        items[idx].updatedAt = Date()
        persist()
    }

    func cancel(id: UUID) {
        updateStatus(id: id, status: .cancelled)
    }

    func item(id: UUID) -> ScheduledRecording? {
        items.first { $0.id == id }
    }
}
