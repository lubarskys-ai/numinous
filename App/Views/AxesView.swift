import SwiftUI
import UIKit
import NuminousCore

/// Seven parts of a life, each developing on its own.
///
/// PROTOTYPE. The question this is built to answer is whether seven pictures on one screen
/// reads as insight or as a stock-photo wall — so it is deliberately plain, and it carries a
/// preview scrubber (bottom) that no shipping version would.
///
/// It renders `AppModel.axisMaturities()`, which the app already computes: each body region
/// of the 3D avatar has always faded in on its own axis maturity. The only reason you have
/// never seen these seven numbers is that `maturity` averages them into one before anything
/// displays them. Nothing new is being measured here — it just stops averaging.
struct AxesView: View {
    @EnvironmentObject var model: AppModel

    /// Prototype-only: overrides every axis so the whole arc can be seen on a small vault.
    /// `maturityFullPerAxis` is 480 counted links per axis, so a real vault sits near zero
    /// for a long time and the mechanic would be invisible to judge.
    @State private var preview: Double? = nil
    @State private var picking: Axis?

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.axes) { axis in
                        card(axis, maturity: maturity(axis))
                            .onTapGesture { picking = axis }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)

                caption
                scrubber
            }
            .navigationTitle("You")
            .background(Color(.systemGroupedBackground))
            .sheet(item: $picking) { axis in
                AxisImagePicker(axis: axis, maturity: maturity(axis))
            }
        }
    }

    private func maturity(_ axis: Axis) -> Double {
        preview ?? (model.axisMaturities()[axis.id] ?? 0)
    }

    private func card(_ axis: Axis, maturity m: Double) -> some View {
        let option = AxisArt.chosen(for: axis.id)
        return VStack(alignment: .leading, spacing: 0) {
            Image(uiImage: AxisArt.rendered(option, tint: UIColor(axis.color), maturity: m))
                .resizable()
                .interpolation(.none)          // never let SwiftUI smooth the blocks back out
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text(axis.name).font(.subheadline.weight(.semibold))
                Text(readout(m)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Words, not a percentage. A number invites you to farm it, which is the one thing this
    /// app is not for.
    private func readout(_ m: Double) -> String {
        switch m {
        case ..<0.02:  return "Nothing here yet"
        case ..<0.15:  return "Barely there"
        case ..<0.35:  return "Taking shape"
        case ..<0.60:  return "Coming through"
        case ..<0.85:  return "Nearly whole"
        default:       return "Whole"
        }
    }

    private var caption: some View {
        Text("Each part comes into focus on its own. Tap one to choose what it looks like.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
    }

    private var scrubber: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 14)
            Text("PROTOTYPE — PREVIEW GROWTH")
                .font(.caption2.weight(.semibold)).kerning(0.6).foregroundStyle(.tertiary)
            HStack {
                Slider(value: Binding(get: { preview ?? 0 }, set: { preview = $0 }), in: 0...1)
                Button("Real") { preview = nil }.font(.caption)
            }
            Text("Drag to see the whole arc. “Real” goes back to your actual growth.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 30)
    }
}

/// Pick the picture for one axis. Options are shown at the axis's CURRENT maturity, not
/// clear — you are choosing the thing you will actually be looking at for months.
private struct AxisImagePicker: View {
    @Environment(\.dismiss) private var dismiss
    let axis: Axis
    let maturity: Double

    @State private var chosen: String = ""

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AxisArt.options(for: axis.id)) { option in
                        Button {
                            AxisArt.choose(option, for: axis.id)
                            chosen = option.id
                        } label: {
                            VStack(spacing: 8) {
                                Image(uiImage: AxisArt.rendered(option, tint: UIColor(axis.color), maturity: maturity))
                                    .resizable()
                                    .interpolation(.none)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(chosen == option.id ? Color.accentColor : .clear, lineWidth: 3)
                                    }
                                Text(option.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                Text("Shown as they look right now, at this part's current growth.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
            }
            .navigationTitle(axis.name)
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { chosen = AxisArt.chosen(for: axis.id).id }
        }
    }
}
