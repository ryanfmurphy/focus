import SwiftUI

// Mandatory 1–10 rating. Presented with .interactiveDismissDisabled(true) and no
// cancel button, so — like the Mac's no-escape modal — the only way out is to
// pick a rating.
struct RatingView: View {
    let focus: String
    var onSubmit: (Int) -> Void

    @State private var rating: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("Time's up").font(.title2).bold()
                    Text(focus)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                Text("How did this session go?")
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                    ForEach(1...10, id: \.self) { n in
                        Button {
                            rating = n
                        } label: {
                            Text("\(n)")
                                .font(.system(.title3, design: .rounded))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(rating == n ? Color.accentColor : Color(.secondarySystemBackground))
                                .foregroundStyle(rating == n ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    if let rating { onSubmit(rating) }
                } label: {
                    Text("Save")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(rating == nil)
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
    }
}
