import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import NuminousCore

/// One part of a life, on its own page, reached from its own name in Setup.
///
/// The alternative — all seven floating on one canvas — costs more than it looks. Seven live
/// shader passes have to be composited and transformed together, which is where every round
/// of jerkiness came from, and it needs a whole field of its own with pan, pinch, hand-placed
/// anchors and hit-testing above a flattened layer. One at a time, none of that exists.
///
/// The page below the picture answers the three questions the picture raises and can't
/// settle: how far along is this, what put it there, and what would move it. Choosing the
/// picture is a rare act and lives behind a button; these are why you came.
struct AxisDetailView: View {
    @EnvironmentObject var model: AppModel
    let axis: Axis

    @State private var changingPicture = false
    /// Prototype-only, as on the field: `maturityFullPerAxis` is 480 links per axis, so a
    /// real vault sits near zero and the arc would be unjudgeable without it.
    @State private var preview: Double? = nil

    private var maturity: Double { preview ?? (model.axisMaturities()[axis.id] ?? 0) }

    var body: some View {
        let contributions = model.axisContributions(axis.id)
        ScrollView {
            VStack(spacing: 0) {
                hero
                scrubber
                standing(lastTouched: contributions.lastTouched)
                built(contributions.top)
                advice
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(backdrop)
        .navigationTitle(axis.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Change") { changingPicture = true }
            }
        }
        .sheet(isPresented: $changingPicture) {
            AxisPicturePicker(axis: axis)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        let option = AxisArt.chosen(for: axis.id)
        let m = maturity
        return VStack(spacing: 14) {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let mv = AxisMotion.values(axis.id, t)
                // An imported animation plays; otherwise the still picture, moved by the
                // per-axis motion. Both go through the same resolve shader either way.
                Image(uiImage: AxisArt.frame(forAxis: axis.id, at: t)
                        ?? AxisArt.artwork(option, axisID: axis.id)
                        ?? AxisArt.source(option, tint: UIColor(axis.color)))
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: 180, height: 180)
                    .resolving(maturity: m, side: 180,
                               seed: Double(abs(axis.id.hashValue % 997)))
                    .scaleEffect(x: mv.sx, y: mv.sy)
                    .rotationEffect(.degrees(mv.rot))
                    .offset(y: mv.dy)
            }
            .frame(height: 200)
            Text(AxisState.words(for: m)).font(.title3).fontDesign(.serif)
        }
        .padding(.top, 14)
    }

    // MARK: - Where it stands

    private func standing(lastTouched: Date?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            figure("\(Int((maturity * 100).rounded()))%", "of the way there")
            Divider().frame(height: 34)
            figure(Self.sinceLabel(lastTouched), Self.sinceCaption(lastTouched))
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 26)
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.title2.weight(.medium)).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// "How long since anything touched this" is the question the percentage can't answer —
    /// an axis can be a third grown and stone dead for four months, and only the date says so.
    private static func sinceLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        switch days {
        case ..<1:  return "Today"
        case 1:     return "1 day"
        case ..<31: return "\(days) days"
        case ..<365:
            let months = max(1, days / 30)
            return months == 1 ? "1 month" : "\(months) months"
        default:
            let years = max(1, days / 365)
            return years == 1 ? "1 year" : "\(years) years"
        }
    }

    private static func sinceCaption(_ date: Date?) -> String {
        date == nil ? "nothing here yet" : "since you last touched it"
    }

    // MARK: - What built it

    private func built(_ top: [(id: UUID, title: String, links: Int)]) -> some View {
        Group {
            if !top.isEmpty {
                section("WHAT BUILT IT") {
                    VStack(spacing: 0) {
                        ForEach(Array(top.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Divider().padding(.leading, 14) }
                            HStack(spacing: 11) {
                                Circle().fill(axis.color).frame(width: 7, height: 7)
                                Text(item.title).lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(item.links)")
                                    .font(.footnote).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("Counted connections touching \(axis.name).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - What would move it

    private var advice: some View {
        section("WHAT WOULD MOVE IT") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.footnote).foregroundStyle(axis.color).padding(.top, 3)
                Text(AxisAdvice.suggestion(for: axis.id))
                    .fontDesign(.serif)
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption2.weight(.semibold)).kerning(0.8).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 26)
    }

    /// Directly under the picture, deliberately: at the foot of the page you had to scroll
    /// the icon out of sight to reach the control that changes it.
    private var scrubber: some View {
        HStack(spacing: 10) {
            Text("PREVIEW")
                .font(.caption2.weight(.semibold)).kerning(0.6).foregroundStyle(.tertiary)
            Slider(value: Binding(get: { preview ?? 0 }, set: { preview = $0 }), in: 0...1)
            Button("Real") { preview = nil }
                .font(.caption)
                .disabled(preview == nil)
        }
        .padding(.top, 18)
    }

    private var backdrop: some View {
        ZStack {
            Color(.systemGroupedBackground)
            RadialGradient(colors: [axis.color.opacity(0.18), .clear],
                           center: .init(x: 0.5, y: 0.18), startRadius: 0, endRadius: 320)
        }
        .ignoresSafeArea()
    }
}

/// Choosing the picture is a rare act, so it lives behind a button rather than taking the
/// page's best space. Options are shown WHOLE: early on every one of them is the same
/// four-block smudge, and you cannot choose between pictures you can't see.
private struct AxisPicturePicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let axis: Axis

    @State private var chosen: String = ""
    @State private var showFiles = false
    @State private var photo: PhotosPickerItem?
    @State private var importError: String?
    /// A still on its way in, waiting to be framed. Animations skip this — you can't
    /// meaningfully crop thirty frames by hand, and an icon export is already square.
    @State private var editing: PendingImage?
    /// Bumped after an import so the grid and the row above it redraw from the new file.
    @State private var version = 0

    private struct PendingImage: Identifiable { let id = UUID(); let image: UIImage }

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    own
                    builtIn
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(axis.name) picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { chosen = AxisArt.chosen(for: axis.id).id }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .gif, .png]) { result in
                switch result {
                case .success(let url): importFile(url)
                case .failure(let error): importError = error.localizedDescription
                }
            }
            .onChange(of: photo) { item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        importError = AxisArt.ImportError.unreadable.errorDescription; return
                    }
                    apply(data)
                }
            }
            .sheet(item: $editing) { pending in
                AxisImageEditor(image: pending.image, tint: axis.color) { framed in
                    save(framed)
                }
            }
            .alert("Couldn't use that image", isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: { Text(importError ?? "") }
        }
    }

    // MARK: - Your own

    private var own: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR OWN")
                .font(.caption2.weight(.semibold)).kerning(0.8).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                Button { showFiles = true } label: {
                    row("Choose a file", "folder")
                }
                Divider().padding(.leading, 46)
                PhotosPicker(selection: $photo, matching: .images) {
                    row("Choose a photo", "photo.on.rectangle")
                }
                if AxisArt.hasCustomArtwork(axisID: axis.id) {
                    Divider().padding(.leading, 46)
                    Button {
                        AxisArt.removeArtwork(forAxis: axis.id)
                        version += 1
                    } label: {
                        row("Use the built-in picture", "arrow.uturn.backward", tint: .secondary)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("Animated GIF and APNG play; a still PNG works too. A transparent background looks best — these float with nothing behind them — and a plain white one is removed for you.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .id(version)
    }

    private func row(_ title: String, _ symbol: String, tint: Color = .accentColor) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(tint)
            Text(title).foregroundStyle(tint == .secondary ? Color.secondary : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    // MARK: - Built in

    private var builtIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BUILT IN")
                .font(.caption2.weight(.semibold)).kerning(0.8).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(AxisArt.options(for: axis.id)) { option in
                    Button {
                        AxisArt.choose(option, for: axis.id)
                        chosen = option.id
                    } label: {
                        VStack(spacing: 9) {
                            // Whole, not at current growth: early on every option is the same
                            // smudge, and you cannot choose between pictures you can't see.
                            Image(uiImage: AxisArt.optionArtwork(option)
                                    ?? AxisArt.source(option, tint: UIColor(axis.color)))
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(1, contentMode: .fit)
                                .padding(12)
                                .background {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(chosen == option.id ? axis.color.opacity(0.16) : .clear)
                                }
                            Text(option.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .id(version)
            if AxisArt.hasCustomArtwork(axisID: axis.id) {
                Text("Your own picture is in use, so these are set aside until you go back to them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Doing the import

    private func importFile(_ url: URL) {
        // A file picked from Files arrives security-scoped; without this the read fails.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            importError = AxisArt.ImportError.unreadable.errorDescription
            return
        }
        apply(data)
    }

    /// Animated first, still second. A GIF or APNG that turns out to hold one frame reports
    /// false rather than throwing, so a single-frame file is imported as the picture it is
    /// instead of failing for not being a movie.
    private func apply(_ data: Data) {
        do {
            // Animated first. A GIF or APNG that turns out to hold one frame reports false
            // rather than throwing, so a single-frame file carries on as a still.
            if try AxisArt.importAnimation(data: data, forAxis: axis.id) {
                finish(); return
            }
        } catch {
            importError = error.localizedDescription; return
        }
        guard let image = UIImage(data: data) else {
            importError = AxisArt.ImportError.unreadable.errorDescription; return
        }
        // A still gets framed first: a photo is rarely square, upright, or centred on its
        // subject, and none of that can be fixed once it is a 40pt picture in a list.
        editing = PendingImage(image: image)
    }

    private func save(_ image: UIImage) {
        do {
            try AxisArt.importArtwork(image, forAxis: axis.id)
            finish()
        } catch {
            importError = error.localizedDescription
        }
    }

    private func finish() {
        version += 1
        model.bumpRevision()
    }
}

/// How each part of a life moves. A still symbol is a still symbol, but a heart that beats is
/// a heart — this is where the character lives.
enum AxisMotion {
    struct Values {
        var sx: CGFloat = 1
        var sy: CGFloat = 1
        var rot: Double = 0
        var dy: CGFloat = 0
    }

    /// Each part moves the way that part of a life moves. This is where the character lives
    /// now: a still symbol is a still symbol, but a heart that beats is a heart.
    static func values(_ axisID: String, _ t: TimeInterval) -> Values {
        switch axisID {
        case "heart":
            // Lub-dub, then rest. Two Gaussian pulses in a 1.5s cycle — a plain sine reads as
            // throbbing, not as a heartbeat, because the rest between beats is the whole tell.
            let p = t.truncatingRemainder(dividingBy: 1.5) / 1.5
            let lub = exp(-pow((p - 0.05) / 0.045, 2))
            let dub = exp(-pow((p - 0.19) / 0.055, 2)) * 0.62
            let k = CGFloat(lub + dub)
            return Values(sx: 1 + 0.11 * k, sy: 1 + 0.11 * k)
        case "body":
            // A flex: one sharp squeeze every couple of seconds, not a constant wobble. sin^6
            // holds it at rest for most of the cycle, which is what makes it read as an effort.
            let p = t.truncatingRemainder(dividingBy: 2.2) / 2.2
            let e = CGFloat(pow(sin(p * .pi), 6))
            return Values(sx: 1 + 0.06 * e, sy: 1 - 0.05 * e, rot: Double(-5 * e))
        case "mind":
            let k = CGFloat(sin(t / 1.7))
            return Values(sx: 1 + 0.02 * k, sy: 1 + 0.02 * k, rot: sin(t / 3.4) * 1.5)
        case "gut":
            return Values(rot: sin(t / 1.9) * 3.5)
        case "meaning":
            // Slow and geological — mountains shouldn't fidget.
            return Values(sy: 1 + 0.015 * CGFloat(sin(t / 3.2)), dy: CGFloat(sin(t / 3.2)) * 3)
        case "influences":
            // A bob, as if spoken.
            let p = t.truncatingRemainder(dividingBy: 2.0) / 2.0
            return Values(dy: -CGFloat(abs(sin(p * .pi))) * 5)
        case "spirit":
            let k = CGFloat(sin(t / 1.25))
            return Values(sx: 1 + 0.06 * k, sy: 1 + 0.06 * k, rot: sin(t / 3.1) * 9)
        default:
            return Values(sy: 1 + 0.02 * CGFloat(sin(t / 2.0)))
        }
    }
}

/// How far along a part of a life is, in words.
enum AxisState {
    static func words(for m: Double) -> String {
        switch m {
        case ..<0.02:  return "Nothing here yet"
        case ..<0.15:  return "Barely there"
        case ..<0.35:  return "Taking shape"
        case ..<0.60:  return "Coming through"
        case ..<0.85:  return "Nearly whole"
        default:       return "Whole"
        }
    }
}

/// One concrete thing that would move an axis. Shared, so Home and the axis page can't drift
/// into saying different things about the same part of a life.
enum AxisAdvice {
    static func suggestion(for axisID: String) -> String {
        let options = table[axisID] ?? generic
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return options[day % options.count]
    }

    private static let generic = [
        "Give it an hour this week and note what came of it.",
        "One small thing here would move it more than you'd think."
    ]

    private static let table: [String: [String]] = [
        "body": ["A walk somewhere you haven't been would do it.",
                 "The workout you already did counts — it just isn't written down.",
                 "Something that leaves you out of breath, once this week."],
        "gut": ["Cook something you've never made.",
                "Note the meal that was actually worth it.",
                "Eat somewhere new rather than somewhere good."],
        "mind": ["The book you keep meaning to open.",
                 "Twenty pages of something hard.",
                 "Write down what stuck from the last thing you read."],
        "meaning": ["One night away somewhere you've never been.",
                    "The project you keep postponing — an hour of it.",
                    "Somewhere new, even if it's close."],
        "heart": ["Call the person you've drifted from.",
                  "See someone in person rather than texting them.",
                  "Write down who you saw this week, and what you talked about."],
        "spirit": ["Ten minutes outside with no phone.",
                   "Sit with something for a while before writing about it.",
                   "Notice one thing today you'd normally walk past."],
        "influences": ["The person whose thinking changed yours — note why.",
                       "Where did that idea actually come from?",
                       "Follow one thing back to its source."]
    ]
}
