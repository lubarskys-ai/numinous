import SwiftUI
import UIKit
import NuminousCore

/// The Avatar tab: the 3D figure itself — grey when young, taking on each axis's
/// color as it matures. Drag to rotate, pinch to zoom. A gentle "Numinous
/// noticed…" reflection may sit beneath it.
/// Wrapper so a tapped note id can drive a `.sheet(item:)`.
private struct IdentifiedID: Identifiable { let id: UUID }

struct AvatarView: View {
    @EnvironmentObject var model: AppModel
    @State private var reflection: ReflectionRecord?
    @State private var zoom: Double = 1
    @State private var committedZoom: Double = 1
    @State private var openNote: IdentifiedID?

    var body: some View {
        let balance = model.score.axisBalance(over: model.axes)
        let graphNodes: [GraphNode] = model.notes.compactMap { note in
            guard !note.isStub, let axis = model.axis(for: note) else { return nil }
            return GraphNode(id: note.id, axis: axis.id, label: note.displayName)
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
                        growth: { min(1, model.score.revealedTotals.points($0) / 150) * model.axisVitality($0) },
                        regionMaturity: { model.axisMaturity($0) },
                        nodes: graphNodes,
                        links: graphLinks,
                        maturity: model.maturity,
                        zoom: zoom,
                        onTapNode: { openNote = IdentifiedID(id: $0) },
                        onZoomChange: { zoom = $0; committedZoom = $0 }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .sheet(item: $openNote) { wrapped in
                NavigationStack { NoteDetailView(noteID: wrapped.id) }
            }
        }
        .preferredColorScheme(.dark)
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
        let clamped = min(30, max(0.12, z))
        zoom = clamped
        committedZoom = clamped
    }
}
