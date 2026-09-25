import Foundation
import UserNotifications

final class ScheduleNotificationService {
    static let shared = ScheduleNotificationService()

    private init() {}

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notify(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func scheduleStartReminder(for recording: ScheduledRecording) {
        guard recording.notifyIfAppInactive else { return }
        let content = UNMutableNotificationContent()
        content.title = recording.title
        content.body = "Scheduled recording is starting now. Open Scripta to record."
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: recording.startAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let id = "schedule-start-\(recording.id.uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelStartReminder(for id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["schedule-start-\(id.uuidString)"]
        )
    }
}
