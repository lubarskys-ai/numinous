import SwiftUI

/// A full-screen `AvatarView` with a close button — used for both the connections graph and
/// the figure, which are now separate screens showing the same scene in different modes.
struct AvatarExpandedView: View {
    var mode: AvatarMode = .graph
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AvatarView(initialMode: mode)
            // BOTTOM left, not top right: the top right belongs to the screen's own menu, and
            // two controls stacked in one corner is how the photo picker became unreachable.
            .overlay(alignment: .bottomLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .padding(.bottom, 30)
            }
    }
}
