import Foundation
import UserNotifications

/// Posts "Notes ready" and friends, and routes their buttons back to the app.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called when a notification about a session is clicked: (session folder, open the review window?).
    var onOpen: ((URL, Bool) -> Void)?

    private nonisolated static let sessionCategory = "session"
    private nonisolated static let reviewCategory = "review"
    private nonisolated static let reviewAction = "review"
    private nonisolated static let notesAction = "notes"

    /// `nil` when running outside an app bundle (e.g. `swift run`), where the
    /// notification center isn't available.
    private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier == nil ? nil : .current()

    override init() {
        super.init()
        guard let center else { return }
        center.delegate = self
        let notes = UNNotificationAction(identifier: Self.notesAction, title: "Open Notes")
        let review = UNNotificationAction(identifier: Self.reviewAction, title: "Review", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.sessionCategory, actions: [notes], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.reviewCategory, actions: [review, notes], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, session: URL? = nil, review: Bool = false) {
        guard let center else {
            FileHandle.standardError.write(Data("\(title): \(body)\n".utf8))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let session {
            content.userInfo = ["session": session.path, "review": review]
            content.categoryIdentifier = review ? Self.reviewCategory : Self.sessionCategory
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard let path = info["session"] as? String else { completionHandler(); return }
        // Clicking the banner itself reviews when there's something to review.
        let review = action == Self.reviewAction || (action == UNNotificationDefaultActionIdentifier && info["review"] as? Bool == true)
        Task { @MainActor in self.onOpen?(URL(fileURLWithPath: path), review) }
        completionHandler()
    }

    /// Show banners even though the menu-bar app counts as frontmost while its menu is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
