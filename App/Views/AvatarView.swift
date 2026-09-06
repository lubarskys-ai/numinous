import SwiftUI
import UIKit
import NuminousCore

/// One screen, two things it can show — see `AvatarMode`.
///
/// In `.graph` it is your connections and nothing else: force-directed, clusters spread, no
/// figure pulling on the layout. In `.avatar` it is the figure and nothing else: solid,
/// growing region by region as each axis fills, with no note-dots inside it.
///
/// They were the same screen once, and the fusion cost both of them. A graph bent toward a
/// silhouette is a picture of the app; a body made of dots can only ever be suggestive.
struct AvatarView: View {
    var initialMode: AvatarMode = .graph
    @EnvironmentObject var model: AppModel
    @State private var mode: AvatarMode?
    @State private var pickingPhoto = false
    /// Reloaded rather than watched: the photo changes when you choose one, and never after.
    @State private var photo: (person: UIImage, anchors: PhotoAvatar.Anchors)?
    /// Only the first sight of a newly chosen photo plays the erasure; opening the screen
    /// again afterwards would make it a performance rather than a beginning.
    @State private var justChosen = false
    /// Bumped to replay the dissolve on demand.
    @State private var replays = 0
    private var shown: AvatarMode { mode ?? initialMode }
    @State private var reflection: ReflectionRecord?
    @State private var zoom: Double = 1
    @State private var committedZoom: Double = 1
    @State private var path: [UUID] = []
    @State private var nodeLabels: [NodeLabel] = []
    @State private var focusName: String?     // node whose connections are spotlighted

    var body: some View {
        let balance = model.score.axisBalance(over: model.lifeAxes)
        // Cached in the model, rebuilt only when data changes — no per-render/per-zoom scan.
        let (graphNodes, graphLinks) = model.avatarGraph()
        // Resolve the axis→(color/growth/maturity) lookups into plain value dictionaries on
        // the main thread, so the scene can be built on a BACKGROUND thread without touching
        // the model (see Avatar3DView's async build). Only a handful of axes, so this is cheap.
        let (axisColor, axisGrowth, axisMat): ([String: UIColor], [String: CGFloat], [String: Double]) = {
            let axisIDs = Set(model.axes.map(\.id)).union(["mind", "meaning", "heart", "spirit", "gut", "body", "influences"])
            var c: [String: UIColor] = [:], g: [String: CGFloat] = [:], m: [String: Double] = [:]
            for a in axisIDs {
                c[a] = UIColor(model.axis(id: a)?.color ?? .gray)
                g[a] = min(1, CGFloat(model.score.revealedTotals.points(a) / 150)) * CGFloat(model.axisVitality(a))
                m[a] = model.axisMaturity(a)
            }
            return (c, g, m)
        }()

        NavigationStack(path: $path) {
            ZStack {
                spaceBackground.ignoresSafeArea()
                // The avatar gets the WHOLE screen. The reflection and the zoom controls float
                // over it — as a VStack sibling, the reflection card was taking real layout
                // space and squeezing the figure into the top half.
                if shown == .avatar, let photo {
                    // YOUR OWN PHOTOGRAPH, when you have chosen one. It replaces the modelled
                    // figure rather than sitting beside it, because the two say the same thing
                    // and only one of them is you.
                    PhotoAvatarView(person: photo.person, anchors: photo.anchors,
                                    maturity: { model.axisMaturity($0) },
                                    spiritColor: model.axis(id: "spirit")?.color ?? .purple,
                                    introduce: justChosen || replays > 0)
                        // A new identity restarts the view, which is what re-runs the intro.
                        .id(replays)
                } else {
                Avatar3DView(
                    mode: shown,
                    color: { axisColor[$0] ?? .gray },
                    growth: { axisGrowth[$0] ?? 0 },
                    regionMaturity: { axisMat[$0] ?? 0 },
                    nodes: graphNodes,
                    links: graphLinks,
                    maturity: model.maturity,
                    zoom: zoom,
                    onTapNode: { path.append($0) },
                    onZoomChange: { zoom = $0; committedZoom = $0 },
                    onLabels: { nodeLabels = $0 },
                    onFocus: { name in withAnimation(.easeInOut(duration: 0.2)) { focusName = name } },
                    focusRequest: model.avatarFocus
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // NOT pixellated here, though it should be. SwiftUI's layerEffect samples a
                // rasterised layer, and an SCNView is drawn by Metal outside that tree — so
                // the shader reads undefined memory and paints a mosaic that does not change
                // when the scene does. It looked like a tuning problem for two rounds; it is
                // not one, and no value of blocksAtZero fixes it.
                //
                // The pixellation has to happen INSIDE SceneKit — a SCNTechnique rendering to
                // a small offscreen target and blitting it back up with nearest-neighbour
                // filtering, which is the same trick at a lower level.
                .overlay { if shown == .graph { labelOverlay } }
                .overlay(alignment: .top) { if shown == .graph { focusPill } }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 10) {
                        HStack { Spacer(); zoomControls }
                        if let reflection {
                            reflectionCard(reflection, tint: dominantColor(balance))
                                // It sits over your avatar now, so you can put it away.
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { self.reflection = nil } }
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                }
            }
            .navigationTitle(shown == .graph ? "Connections" : "You")
            // Both screens, one tap apart. Which one you land on depends on how you got here —
            // tapping the little figure opens the figure; "see in graph" opens the graph.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if shown == .avatar {
                        Menu {
                            Button(photo == nil ? "Use a photo of me…" : "Choose a different photo…",
                                   systemImage: "photo") { pickingPhoto = true }
                            if photo != nil {
                                // Handy while the timing is still being argued about, and
                                // worth keeping afterwards: it is a nice thing to watch.
                                Button("Play the erasure again", systemImage: "arrow.counterclockwise") {
                                    replays += 1
                                }
                                Button("Back to the drawn figure", systemImage: "figure.stand",
                                       role: .destructive) {
                                    PhotoAvatar.forget(); photo = nil
                                }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            mode = shown == .graph ? .avatar : .graph
                        }
                    } label: {
                        Label(shown == .graph ? "You" : "Connections",
                              systemImage: shown == .graph ? "figure.stand"
                                                           : "point.3.connected.trianglepath.dotted")
                            .labelStyle(.titleAndIcon)
                            .font(.footnote)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .onAppear {
                if reflection == nil { reflection = model.currentReflection() }
                if photo == nil { photo = PhotoAvatar.stored() }
            }
            .sheet(isPresented: $pickingPhoto) {
                PhotoAvatarPicker { photo = PhotoAvatar.stored(); justChosen = true }
            }
            .onDisappear { model.avatarFocus = nil }   // don't re-focus next time the avatar opens
            // Push within the avatar's own stack rather than a sheet: this view lives
            // inside a full-screen cover, and a sheet presented from there fails silently.
            .navigationDestination(for: UUID.self) { id in
                NoteDetailView(noteID: id)
            }
        }
        .preferredColorScheme(.dark)
    }


    /// Names for the few nodes nearest the centre when zoomed in — drawn in 2D over the
    /// scene (no 3D text), positioned from Avatar3DView's per-frame projection.
    private var labelOverlay: some View {
        ForEach(nodeLabels) { label in
            Text(label.text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule())
                .fixedSize()
                .position(x: label.point.x, y: label.point.y - 15)
                .allowsHitTesting(false)
        }
    }

    /// When a node is spotlighted, a banner names it and explains the gesture (tap it again
    /// to open the note, tap empty space to clear).
    @ViewBuilder private var focusPill: some View {
        if let focusName {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.caption)
                    Text(focusName).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Text("tap again to open · tap empty space to clear")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
            .padding(.top, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// A deep-space backdrop so the connectome and stardust actually glow.
    /// A quiet dark ground, no longer a night sky.
    ///
    /// The blue-black vignette was the far end of the space theme — it read as deep space
    /// because it was meant to. A graph of your notes wants a surface to sit on, and a
    /// photograph brings its own light, so both are better served by something that stays out
    /// of the way.
    private var spaceBackground: some View {
        Color(red: 0.07, green: 0.07, blue: 0.075)
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
        (model.lifeAxes.max { (b[$0.id] ?? 0) < (b[$1.id] ?? 0) })?.color ?? .accentColor
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
        let clamped = min(120, max(0.12, z))
        zoom = clamped
        committedZoom = clamped
    }
}
