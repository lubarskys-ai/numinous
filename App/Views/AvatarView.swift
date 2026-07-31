import SwiftUI
import UIKit
import NuminousCore

/// The Avatar tab: the 3D figure itself — grey when young, taking on each axis's
/// color as it matures. Drag to rotate, pinch to zoom. A gentle "Numinous
/// noticed…" reflection may sit beneath it.
struct AvatarView: View {
    @EnvironmentObject var model: AppModel
    @State private var reflection: ReflectionRecord?
    @State private var zoom: Double = 1
    @State private var committedZoom: Double = 1
    @State private var growthPreview: Double?

    var body: some View {
        let balance = model.score.axisBalance(over: model.axes)
        let graphNodes: [GraphNode] = model.notes.compactMap { note in
            guard !note.isStub, let axis = model.axis(for: note) else { return nil }
            return GraphNode(id: note.id, axis: axis.id)
        }
        let graphLinks: [GraphEdge] = model.score.links
            .filter(\.isCounted)
            .map { GraphEdge(a: $0.a, b: $0.b, cross: $0.isCrossAxis) }

        NavigationStack {
            ZStack {
                spaceBackground.ignoresSafeArea()
                VStack(spacing: 12) {
                    Avatar3DView(
                        color: { UIColor(model.axis(id: $0)?.color ?? .gray) },
                        growth: { min(1, model.score.revealedTotals.points($0) / 150) },
                        nodes: graphNodes,
                        links: graphLinks,
                        maturity: growthPreview ?? model.maturity,
                        zoom: zoom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { zoom = min(30, max(0.5, committedZoom * $0)) }
                            .onEnded { _ in committedZoom = zoom }
                    )
                    .overlay(alignment: .bottomLeading) { growButton.padding(14) }
                    .overlay(alignment: .bottomTrailing) { zoomControls.padding(14) }

                    if let reflection {
                        reflectionCard(reflection, tint: dominantColor(balance))
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
            .navigationTitle("Numinous")
            .toolbarBackground(.hidden, for: .navigationBar)
            .onAppear { if reflection == nil { reflection = model.currentReflection() } }
        }
        .preferredColorScheme(.dark)
    }

    /// "Watch it grow" — replays the birth sequence from stars to formed body.
    private var growButton: some View {
        Button {
            guard growthPreview == nil else { return }
            Task { @MainActor in
                let steps = 34
                for step in 0...steps {
                    growthPreview = Double(step) / Double(steps)
                    try? await Task.sleep(nanoseconds: 260_000_000)
                }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                growthPreview = nil
            }
        } label: {
            Label(growthPreview == nil ? "Watch it grow" : "Growing…", systemImage: "sparkles")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .disabled(growthPreview != nil)
    }

    /// A deep-space backdrop so the connectome and stardust actually glow.
    private var spaceBackground: some View {
        RadialGradient(
            colors: [Color(red: 0.07, green: 0.08, blue: 0.15), Color(red: 0.02, green: 0.02, blue: 0.05)],
            center: .center, startRadius: 40, endRadius: 620
        )
    }

    /// "Numinous noticed…" — the app reflecting a true pattern back to you.
    private func reflectionCard(_ record: ReflectionRecord, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Numinous noticed").font(.caption.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(tint)
            Text(record.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Got it") {
                    model.acknowledgeReflection(record)
                    withAnimation { reflection = model.currentReflection() }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.25)))
    }

    private func dominantColor(_ b: AxisTotals) -> Color {
        (model.axes.max { (b[$0.id] ?? 0) < (b[$1.id] ?? 0) })?.color ?? .accentColor
    }

    /// +/- buttons — a zoom that works with a single tap/click (no pinch needed).
    private var zoomControls: some View {
        VStack(spacing: 1) {
            zoomButton("plus") { setZoom(zoom * 1.4) }
            Divider().frame(width: 28)
            zoomButton("minus") { setZoom(zoom / 1.4) }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.2)))
    }

    private func zoomButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "\(icon).magnifyingglass")
                .font(.body).frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
    }

    private func setZoom(_ z: Double) {
        let clamped = min(30, max(0.5, z))
        zoom = clamped
        committedZoom = clamped
    }
}
