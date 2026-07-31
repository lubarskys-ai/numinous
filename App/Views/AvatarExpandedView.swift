import SwiftUI

/// The full 3D connectome avatar, shown when you tap the little companion. Reuses
/// the avatar screen and adds a close button.
struct AvatarExpandedView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AvatarView()
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
