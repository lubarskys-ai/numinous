import SwiftUI

/// A full-screen `AvatarView` with a close button — used for both the connections graph and
/// the figure, which are now separate screens showing the same scene in different modes.
struct AvatarExpandedView: View {
    var mode: AvatarMode = .graph
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AvatarView(initialMode: mode)
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                .padding(.trailing, 14)
            }
    }
}
