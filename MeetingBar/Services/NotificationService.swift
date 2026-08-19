import Foundation
import UserNotifications

struct NotificationService: Sendable {
  func requestAuthorization() async -> Bool {
    (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
  }

  func notifyTranscriptionReady(title: String) async {
    let content = UNMutableNotificationContent()
    content.title = "Transcript ready"
    content.body = title
    content.sound = .default
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    try? await UNUserNotificationCenter.current().add(request)
  }

  func notifyTranscriptionFailed(title: String) async {
    let content = UNMutableNotificationContent()
    content.title = "Transcription failed"
    content.body = "Open MeetingBar to retry \(title)."
    content.sound = .default
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    try? await UNUserNotificationCenter.current().add(request)
  }
}

