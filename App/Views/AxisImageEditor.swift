import SwiftUI
import UIKit

/// Crop and straighten a picture before it becomes an axis's artwork.
///
/// These are drawn square and float with nothing behind them, so a photo taken in landscape,
/// or a screenshot with the subject off to one side, needs framing before it means anything
/// at 40pt in a list. Pinch and drag to place it, turn it if it came in sideways.
///
/// The crop is produced by rendering THIS VIEW rather than by recomputing the transform in a
/// graphics context: what you framed is what gets saved, and there is no second implementation
/// of the maths to disagree with the preview.
struct AxisImageEditor: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let tint: Color
    let onUse: (UIImage) -> Void

    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @State private var quarterTurns = 0
    @State private var fineAngle: Double = 0

    /// The framed square, in points. The saved file is rendered from this at 512.
    private let side: CGFloat = 300

    private var zoom: CGFloat { min(6, max(0.3, scale * pinch)) }
    private var angle: Angle { .degrees(Double(quarterTurns) * 90 + fineAngle) }
    private var isDefault: Bool {
        zoom == 1 && offset == .zero && drag == .zero && quarterTurns == 0 && fineAngle == 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                framed
                    .overlay {
                        // The frame, not a mask: you need to see what is about to be cut off.
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(tint.opacity(0.7), lineWidth: 2)
                    }
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .gesture(
                        DragGesture()
                            .updating($drag) { v, state, _ in state = v.translation }
                            .onEnded { v in
                                offset.width += v.translation.width
                                offset.height += v.translation.height
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .updating($pinch) { v, state, _ in state = v }
                            .onEnded { v in scale = min(6, max(0.3, scale * v)) }
                    )

                controls
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Frame it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if let cropped = render() { onUse(cropped) }
                        dismiss()
                    }
                }
            }
        }
    }

    /// The square, exactly as it will be saved.
    private var framed: some View {
        Color.clear
            .frame(width: side, height: side)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .rotationEffect(angle)
                    .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var controls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 26) {
                Button { withAnimation(.snappy) { quarterTurns -= 1 } } label: {
                    Label("Left", systemImage: "rotate.left")
                }
                Button { withAnimation(.snappy) { quarterTurns += 1 } } label: {
                    Label("Right", systemImage: "rotate.right")
                }
                Button {
                    withAnimation(.snappy) {
                        scale = 1; offset = .zero; quarterTurns = 0; fineAngle = 0
                    }
                } label: {
                    Label("Reset", systemImage: "arrow.uturn.backward")
                }
                .disabled(isDefault)
            }
            .labelStyle(.iconOnly)
            .font(.title3)

            VStack(spacing: 4) {
                Slider(value: $fineAngle, in: -20...20)
                Text(fineAngle == 0 ? "Straighten" : String(format: "%.0f°", fineAngle))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("Pinch to zoom, drag to move.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Render the framed square to a 512 image. `isOpaque = false` matters: these float with
    /// nothing behind them, and an opaque render would bake in a black or white square.
    private func render() -> UIImage? {
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 512 / side
        renderer.isOpaque = false
        return renderer.uiImage
    }
}
