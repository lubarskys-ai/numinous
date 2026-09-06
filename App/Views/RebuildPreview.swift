import SwiftUI
import NuminousCore

/// Watch the rebuild without waiting years for it.
///
/// Everything about the dissolve could be judged in nine seconds. The REBUILD is the half that
/// matters and it happens over months, so it cannot be looked at, argued about or corrected in
/// the ordinary way — which is exactly how you end up shipping curves nobody has ever seen.
///
/// This drives the axes by hand instead. All together, to judge the arc; or one at a time, to
/// see whether a head coming back on its own reads as a head coming back or as a smudge over
/// somebody's shoulders. It changes no data and saves nothing.
struct RebuildPreview: View {
    @EnvironmentObject var model: AppModel
    @Binding var values: [String: Double]
    @Binding var showing: Bool

    private let axes = ["mind", "heart", "body", "meaning", "spirit"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Rebuild preview").font(.footnote.weight(.semibold))
                Spacer()
                Button("Done") { showing = false }.font(.footnote)
            }
            HStack(spacing: 10) {
                Text("All").font(.caption2).frame(width: 46, alignment: .leading)
                Slider(value: Binding(
                    get: { values.values.max() ?? 0 },
                    set: { new in for axis in axes { values[axis] = new } }), in: 0...1)
            }
            ForEach(axes, id: \.self) { axis in
                HStack(spacing: 10) {
                    Circle().fill(model.axis(id: axis)?.color ?? .gray).frame(width: 7, height: 7)
                    Text(model.axis(id: axis)?.name ?? axis)
                        .font(.caption2).frame(width: 60, alignment: .leading)
                    Slider(value: Binding(get: { values[axis] ?? 0 },
                                          set: { values[axis] = $0 }), in: 0...1)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
    }
}
