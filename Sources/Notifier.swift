import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private static let triageCategory = "triage"
    private static let silenceAction = "triage.silence"
    private static let triageKey = "triageID"

    func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Disk alerts carry a "don't tell me about this kind again" button.
        let silence = UNNotificationAction(identifier: Self.silenceAction, title: "这类不用提醒", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.triageCategory, actions: [silence], intentIdentifiers: [], options: [])
        ])
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// - Parameter triageID: set for judged disk alerts, so the notification's button can correct them.
    func send(title: String, body: String, triageID: UUID? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let triageID {
            content.categoryIdentifier = Self.triageCategory
            content.userInfo = [Self.triageKey: triageID.uuidString]
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let triageID = (info[Self.triageKey] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case Self.silenceAction:
                if let triageID { TriageService.shared.correct(triageID, notify: false) }
            case UNNotificationDefaultActionIdentifier where triageID != nil:
                DiskWatchWindowController.shared.show()
            default:
                break
            }
            completionHandler()
        }
    }
}
