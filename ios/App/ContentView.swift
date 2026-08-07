import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(FocusManager.self) private var manager
    @Environment(\.scenePhase) private var scenePhase

    // Most recent sessions, newest first.
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]

    var body: some View {
        @Bindable var manager = manager

        NavigationStack {
            List {
                Section {
                    if manager.active != nil {
                        activeCard
                    } else {
                        idleCard
                    }
                }

                Section("History") {
                    ForEach(sessions.filter { $0.endedAt != nil }) { s in
                        HistoryRow(session: s)
                    }
                }
            }
            .navigationTitle("Focus")
        }
        // Mandatory rating — non-dismissable, the iOS analog of the Mac's
        // no-escape modal.
        .sheet(item: $manager.ratingRequest) { req in
            RatingView(focus: req.session.focus) { rating in
                manager.submitRating(rating)
            }
            .interactiveDismissDisabled(true)
        }
        // Start / change focus form.
        .sheet(isPresented: $manager.showStartForm) {
            StartFocusView { focus, minutes in
                manager.begin(focus: focus, minutes: minutes)
            }
        }
        // Fire the rating the moment the timer runs out while we're on screen.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            manager.handleExpiryIfNeeded()
        }
        // And when returning to the app after the notification fired.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { manager.handleExpiryIfNeeded() }
        }
    }

    private var idleCard: some View {
        Button {
            manager.requestStart()
        } label: {
            Label("Set a focus", systemImage: "scope")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var activeCard: some View {
        if let active = manager.active, let end = manager.endDate {
            VStack(alignment: .leading, spacing: 8) {
                Label(active.focus, systemImage: "scope")
                    .font(.headline)
                Text(timerInterval: Date.now...end, countsDown: true)
                    .font(.system(.largeTitle, design: .rounded))
                    .monospacedDigit()
                HStack {
                    Button("Change") { manager.requestStart() }
                        .buttonStyle(.bordered)
                    Button("Clear", role: .destructive) { manager.requestClear() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct HistoryRow: View {
    let session: Session

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(session.focus).lineLimit(1)
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let rating = session.rating {
                Text("\(rating)/10").monospacedDigit()
            } else {
                Text(session.outcome ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
