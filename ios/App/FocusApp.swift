import SwiftUI
import SwiftData

@main
struct FocusApp: App {
    let container: ModelContainer
    @State private var manager: FocusManager

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Session.self)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        self.container = container
        _manager = State(initialValue: FocusManager(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(manager)
        }
        .modelContainer(container)
    }
}
