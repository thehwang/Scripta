import AppKit
import Foundation
import ScriptaCore

final class SleepAssertionService {
    private var activityToken: NSObjectProtocol?

    func acquire(reason: String = "Scripta is recording") {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: reason
        )
        mplog("Idle sleep disabled (system + display)")
    }

    func release() {
        guard let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
        mplog("Idle sleep assertions released")
    }
}
