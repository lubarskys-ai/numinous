import SwiftUI
import NuminousCore

/// Where the app opens. Not a dashboard — a landing.
///
/// It answers two questions in one glance: *what is this* (the figure you're growing, given
/// the space it deserves) and *what do I do now* (one button — note something). Under that,
/// at most three sentences of what Numinous noticed, drawn from what it already knows. No
/// counts, no streaks, nothing engineered to hold you: everything here is a sentence or a
/// picture, and the whole screen is meant to be finished with in about ten seconds.
struct HomeView: View {
    @EnvironmentObject var model: AppModel

    @State private var digest: AppModel.WeeklyDigest?
    @State private var showCompose = false
    @State private var showAvatar = false
    @State private var showCalendar = false
    @State private var showHealth = false
    @State private var path: [UUID] = []

    var body: some View {
        let balance = model.score.axisBalance(over: model.axes)
        let tint = (model.axes.max { (balance[$0.id] ?? 0) < (balance[$1.id] ?? 0) })?.color ?? .accentColor

        NavigationStack(path: $path) {
            ZStack {
                background(tint)
                ScrollView {
                    VStack(spacing: 26) {
                        figure(tint)
                        captureButton(tint)
                        if !notices.isEmpty { noticeList }
                        elsewhereLinks
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 0)
                    .padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { NoteDetailView(noteID: $0) }
        }
        // The digest walks every note, so build it when the data changes — not per render.
        .task(id: model.notes.count) { digest = model.weeklyDigest() }
        .fullScreenCover(isPresented: $showCompose) { ComposeView(prefillTitle: nil, autofocus: true) }
        .fullScreenCover(isPresented: $showAvatar) { AvatarExpandedView() }
        .fullScreenCover(isPresented: $showCalendar) { closable { CalendarView() } }
        .fullScreenCover(isPresented: $showHealth) { closable { HealthView() } }
    }

    // MARK: - The figure

    private func figure(_ tint: Color) -> some View {
        VStack(spacing: 14) {
            CompanionView(progress: model.maturity, tint: tint, action: .idle, actionStart: .distantPast)
                .frame(width: 200, height: 210)
                // A barely-grown companion draws itself small inside its canvas, which on a
                // near-empty screen reads as a speck rather than a hero. Boost the young ones
                // and ease off as the figure fills its own frame.
                .scaleEffect(1.85 - 0.65 * model.maturity)
                .frame(height: 188)   // the figure sits high in its canvas; don't reserve the dead space below it
                .contentShape(Rectangle())
                .onTapGesture { showAvatar = true }
                .accessibilityLabel("Your avatar. Open it.")
            Text(stageLine)
                .font(.title3)
                .fontDesign(.serif)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
        }
        .padding(.top, 10)
    }

    /// One warm line about where the figure has got to. Staged, never a percentage — the
    /// point is that it grew from a life, not that it's 34% complete.
    private var stageLine: String {
        switch model.maturity {
        case ..<0.15: return "Barely a sketch yet.\nIt fills in as you live."
        case ..<0.40: return "Taking shape — from\nwhat you've actually done."
        case ..<0.70: return "Coming into focus."
        default:      return "Well formed.\nMost of your life is in here."
        }
    }

    // MARK: - The one thing to do

    private func captureButton(_ tint: Color) -> some View {
        Button { showCompose = true } label: {
            Label("Note something", systemImage: "square.and.pencil")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .tint(tint)
    }


    // MARK: - What Numinous noticed

    /// A line worth reading on the way past. Tappable when it points at someone.
    private struct Notice: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let text: String
        let noteID: UUID?
    }

    /// At most three, most-worth-saying first. Deliberately capped: a fourth line turns a
    /// landing into a feed, which is the thing this app is against.
    private var notices: [Notice] {
        guard let digest else { return [] }
        var out: [Notice] = []
        if let reflection = digest.reflection {
            out.append(Notice(icon: "sparkles", tint: .pink, text: reflection, noteID: nil))
        }
        if let nudge = digest.travelNudge {
            out.append(Notice(icon: "globe.americas", tint: .teal, text: nudge, noteID: nil))
        }
        if let person = digest.drifting.first {
            let since = AppModel.outOfTouchLabel(person.lastContact).map { " — \($0)" } ?? ""
            out.append(Notice(icon: "heart", tint: .pink,
                              text: "You've drifted from \(person.name)\(since).", noteID: person.id))
        }
        if let quiet = digest.quietAxisIDs.first, let axis = model.axis(id: quiet) {
            out.append(Notice(icon: "circle", tint: axis.color,
                              text: "\(axis.name) has been quiet this week.", noteID: nil))
        }
        return Array(out.prefix(3))
    }

    private var noticeList: some View {
        VStack(spacing: 0) {
            ForEach(Array(notices.enumerated()), id: \.element.id) { i, notice in
                if i > 0 { Divider().padding(.leading, 44) }
                noticeRow(notice)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.secondary.opacity(0.15)))
    }

    @ViewBuilder
    private func noticeRow(_ notice: Notice) -> some View {
        let row = HStack(alignment: .top, spacing: 12) {
            Image(systemName: notice.icon)
                .font(.footnote)
                .foregroundStyle(notice.tint)
                .frame(width: 20)
                .padding(.top, 2)
            Text(notice.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if notice.noteID != nil {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).padding(.top, 3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())

        if let id = notice.noteID {
            Button { path.append(id) } label: { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    // MARK: - The rest of the app, kept quiet

    private var elsewhereLinks: some View {
        HStack(spacing: 22) {
            Button { showCalendar = true } label: { Label("Calendar", systemImage: "calendar") }
            Button { showHealth = true } label: { Label("Health", systemImage: "heart.text.square") }
        }
        .font(.subheadline)
        .padding(.top, 4)
    }

    /// Calendar and Health were tabs; presented from here they need a way back out.
    private func closable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            content()
            Button { showCalendar = false; showHealth = false } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 8)
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Background

    /// The same calm, axis-tinted wash the onboarding opens on, so arriving here after the
    /// first capture feels like the same place.
    private func background(_ tint: Color) -> some View {
        LinearGradient(colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Circle().fill(tint.opacity(0.14)).frame(width: 340, height: 340)
                    .blur(radius: 90).offset(y: -110)
                    .allowsHitTesting(false)
            }
    }
}
