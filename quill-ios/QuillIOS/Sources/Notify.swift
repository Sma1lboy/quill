import Foundation
import UserNotifications

/// Local notifications for pipeline milestones — visible on the lock screen,
/// so a transcript that finished while the phone was pocketed surfaces.
/// Only fires when the app is backgrounded (foreground already shows the
/// pipeline banner).
enum Notify {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    static func transcriptReady(session: String, hasNotes: Bool) {
        let content = UNMutableNotificationContent()
        content.title = hasNotes ? "quill — notes ready" : "quill — transcript ready"
        content.body = session
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "quill-\(session)",
            content: content,
            trigger: nil // deliver now
        )
        UNUserNotificationCenter.current().add(request)
    }
}
