import Foundation
import ActivityKit

// Shared between the app (which starts/updates the Live Activity) and the widget
// extension (which renders it). Both targets compile this file.
struct FocusAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var focus: String
        var endDate: Date   // used by Text(timerInterval:) to count down without push updates
    }

    var startedAt: Date
}
