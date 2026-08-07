import Foundation
import SwiftData

// The iPhone equivalent of the macOS `sessions` table. Standalone local store
// (SwiftData) for now — same fields, so a later CloudKit/iCloud sync with the
// Mac app stays structurally sane.
@Model
final class Session {
    var startedAt: Date
    var endedAt: Date?
    var minutes: Int          // planned duration
    var focus: String
    var rating: Int?          // 1...10, set when the session is rated
    var outcome: String?      // completed / cleared / superseded / interrupted

    init(startedAt: Date = .now, minutes: Int, focus: String) {
        self.startedAt = startedAt
        self.minutes = minutes
        self.focus = focus
    }
}
