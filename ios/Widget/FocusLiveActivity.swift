import WidgetKit
import SwiftUI
import ActivityKit

// The always-present focus display — the iOS analog of the Mac's floating pill.
// Renders on the Lock Screen / banner and in the Dynamic Island. The countdown
// uses Text(timerInterval:) so it ticks on its own without any push updates.
struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusAttributes.self) { context in
            // Lock Screen / banner presentation.
            HStack(spacing: 12) {
                Text("🎯").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.focus)
                        .font(.headline)
                        .lineLimit(1)
                    countdown(to: context.state.endDate)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("🎯").font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(to: context.state.endDate)
                        .font(.title3)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.focus)
                        .font(.headline)
                        .lineLimit(1)
                }
            } compactLeading: {
                Text("🎯")
            } compactTrailing: {
                countdown(to: context.state.endDate)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } minimal: {
                Text("🎯")
            }
        }
    }

    // Guard the range: once endDate is in the past, Date.now...end would be an
    // invalid range. Clamp the lower bound so it never crashes.
    private func countdown(to end: Date) -> Text {
        Text(timerInterval: min(Date.now, end)...end, countsDown: true)
    }
}
