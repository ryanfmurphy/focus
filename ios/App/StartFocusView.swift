import SwiftUI

// The "what's your focus, and for how long?" form — the iOS counterpart of the
// Mac return-prompt (minus the on-unlock trigger, which iOS doesn't allow).
struct StartFocusView: View {
    var onStart: (String, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var focus = ""
    @State private var minutes = 25

    var body: some View {
        NavigationStack {
            Form {
                Section("Focus") {
                    TextField("e.g. Ship the focus app", text: $focus, axis: .vertical)
                }
                Section("Minutes") {
                    Stepper(value: $minutes, in: 1...240) {
                        Text("\(minutes) min").monospacedDigit()
                    }
                }
            }
            .navigationTitle("New focus")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, minutes > 0 else { return }
                        onStart(trimmed, minutes)
                        dismiss()
                    }
                    .disabled(focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
