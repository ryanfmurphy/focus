import Foundation
import SwiftData
import ActivityKit
import UserNotifications

// Owns the active session and everything attached to it: the SwiftData row, the
// Live Activity (Dynamic Island + Lock Screen pill), and the local notification
// that fires when the timer runs out.
//
// iOS reality: unlike the Mac app there is NO way to force a modal when you
// return to the phone. So the mandatory rating is enforced with a
// non-dismissable sheet (see RatingView) that appears when a session ends —
// either because the timer expired (in-app tick or notification tap) or because
// you chose to change/clear the focus.
@MainActor
@Observable
final class FocusManager {
    private let context: ModelContext

    private(set) var active: Session?
    private(set) var endDate: Date?

    // When non-nil, the UI must present the mandatory rating sheet.
    var ratingRequest: RatingRequest?
    // When true, the UI presents the "start a focus" form.
    var showStartForm = false

    private var activity: Activity<FocusAttributes>?

    struct RatingRequest: Identifiable {
        let id = UUID()
        let session: Session
        let outcome: String
        let thenStart: Bool   // change-focus flow: after rating, open the start form
    }

    init(context: ModelContext) {
        self.context = context
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        recoverInterrupted()
    }

    var isExpired: Bool {
        guard let endDate else { return false }
        return Date() >= endDate
    }

    // MARK: - Intents

    /// "+" / Change focus. If a session is running it must be rated first.
    func requestStart() {
        if let s = active {
            ratingRequest = RatingRequest(session: s, outcome: "superseded", thenStart: true)
        } else {
            showStartForm = true
        }
    }

    /// Clear the current focus (still requires a rating).
    func requestClear() {
        if let s = active {
            ratingRequest = RatingRequest(session: s, outcome: "cleared", thenStart: false)
        }
    }

    /// Called by an in-app tick or when the app becomes active after the timer.
    func handleExpiryIfNeeded() {
        guard isExpired, let s = active, ratingRequest == nil else { return }
        ratingRequest = RatingRequest(session: s, outcome: "completed", thenStart: false)
    }

    /// Begin a brand-new session.
    func begin(focus: String, minutes: Int) {
        let s = Session(minutes: minutes, focus: focus)
        context.insert(s)
        try? context.save()

        active = s
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        endDate = end

        startLiveActivity(focus: focus, endDate: end)
        scheduleExpiryNotification(at: end, focus: focus)
        showStartForm = false
    }

    /// Called by the mandatory rating sheet on submit.
    func submitRating(_ rating: Int) {
        guard let req = ratingRequest else { return }
        finalize(req.session, outcome: req.outcome, rating: rating)
        let thenStart = req.thenStart
        ratingRequest = nil
        if thenStart { showStartForm = true }
    }

    // MARK: - Finalize

    private func finalize(_ s: Session, outcome: String, rating: Int) {
        s.endedAt = .now
        s.outcome = outcome
        s.rating = rating
        try? context.save()

        if s === active {
            active = nil
            endDate = nil
        }
        endLiveActivity()
        cancelExpiryNotification()
    }

    /// Any row left open by a crash / force-quit / cold launch is marked
    /// "interrupted" (never rated). Mirrors the orphan-row issue we hit on the Mac.
    private func recoverInterrupted() {
        let openRows = FetchDescriptor<Session>(predicate: #Predicate { $0.endedAt == nil })
        if let rows = try? context.fetch(openRows) {
            for row in rows where row.outcome == nil {
                row.endedAt = .now
                row.outcome = "interrupted"
            }
            try? context.save()
        }
        // End any Live Activities that outlived their process.
        for activity in Activity<FocusAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: - Live Activity

    private func startLiveActivity(focus: String, endDate: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = FocusAttributes(startedAt: .now)
        let state = FocusAttributes.ContentState(focus: focus, endDate: endDate)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: endDate),
                pushType: nil)
        } catch {
            print("Live Activity request failed: \(error)")
        }
    }

    private func endLiveActivity() {
        let current = activity
        activity = nil
        Task { await current?.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Notifications

    private func scheduleExpiryNotification(at date: Date, focus: String) {
        let content = UNMutableNotificationContent()
        content.title = "Time's up"
        content.body = "Rate your focus: \(focus)"
        content.sound = .default

        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let req = UNNotificationRequest(identifier: "focus.expiry", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    private func cancelExpiryNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["focus.expiry"])
    }
}
