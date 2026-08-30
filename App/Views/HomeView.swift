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
    @State private var showGuide = false
    @State private var showCalendar = false
    @State private var showHealth = false
    @State private var path: [UUID] = []
    /// Recent activity that hasn't become a note yet — the only reason to mention Health.
    @State private var unimportedActivity = 0
    /// Offer to connect Health once. Dismissed, it never asks again.
    @AppStorage("health_offer_dismissed") private var healthOfferDismissed = false
    /// Whether Health has ever been asked for. Read once into state: querying it is a hop to
    /// the Health daemon, and doing that from `body` made every render — every tab switch —
    /// pay for two of them.
    @State private var healthAccessAsked = false

    var body: some View {
        let balance = model.score.axisBalance(over: model.axes)
        let tint = (model.axes.max { (balance[$0.id] ?? 0) < (balance[$1.id] ?? 0) })?.color ?? .accentColor
        let shown = notices          // computed once; it used to be evaluated twice per render

        NavigationStack(path: $path) {
            ZStack {
                background(tint)
                ScrollView {
                    VStack(spacing: 26) {
                        figure(tint)
                        captureButton(tint)
                        if !shown.isEmpty { noticeList(shown) }
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
        .task(id: model.notes.count) { digest = model.weeklyDigest(); await countUnimportedActivity() }
        .fullScreenCover(isPresented: $showCompose) { ComposeView(prefillTitle: nil, autofocus: true) }
        .fullScreenCover(isPresented: $showAvatar) { AvatarExpandedView() }
        .sheet(isPresented: $showGuide) { GuideView() }
        .fullScreenCover(isPresented: $showCalendar) { closable { CalendarView() } }
        .fullScreenCover(isPresented: $showHealth) { closable { HealthView() } }
        // They may have granted access in there, which changes what Home should say.
        .onChange(of: showHealth) { open in if !open { Task { await countUnimportedActivity() } } }
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
        enum Action: Equatable { case none, note(UUID), health }
        /// Derived from the content, NOT a fresh UUID. A new id every render makes ForEach
        /// throw away and rebuild every row on each pass, which is felt as tab-switch lag.
        var id: String { icon + "|" + text }
        let icon: String
        let tint: Color
        let text: String
        var action: Action = .none
        /// Shows an explicit dismiss. Only the once-ever offers get one — a notice about
        /// your own life isn't something to swat away.
        var dismissible = false

        init(icon: String, tint: Color, text: String, action: Action = .none, dismissible: Bool = false) {
            self.icon = icon; self.tint = tint; self.text = text
            self.action = action; self.dismissible = dismissible
        }
        init(icon: String, tint: Color, action: Action, dismissible: Bool = false, text: String) {
            self.init(icon: icon, tint: tint, text: text, action: action, dismissible: dismissible)
        }
    }

    /// At most three, most-worth-saying first. Deliberately capped: a fourth line turns a
    /// landing into a feed, which is the thing this app is against.
    private var notices: [Notice] {
        guard let digest else { return [] }
        var out: [Notice] = []
        if let reflection = digest.reflection {
            out.append(Notice(icon: "sparkles", tint: .pink, text: reflection))
        }
        if let nudge = digest.travelNudge {
            out.append(Notice(icon: "globe.americas", tint: .teal, text: nudge))
        }
        if let person = digest.drifting.first {
            let since = AppModel.outOfTouchLabel(person.lastContact).map { " — \($0)" } ?? ""
            out.append(Notice(icon: "heart", tint: .pink,
                              text: "You've drifted from \(person.name)\(since).", action: .note(person.id)))
        }
        if let health = healthNotice {
            out.append(health)
        }
        if let quiet = digest.quietAxisIDs.first, let axis = model.axis(id: quiet) {
            out.append(Notice(icon: "circle", tint: axis.color,
                              text: "\(axis.name) has been quiet this week."))
        }
        return Array(out.prefix(3))
    }

    /// Health, without a tab. Two states worth a line and no others:
    ///
    /// * never connected — offer it once, and only offer. Checking whether we've asked
    ///   doesn't prompt, so nobody gets a system permission sheet for opening the app.
    /// * connected, with activity that isn't a note yet — say how much, once.
    ///
    /// Connected and nothing pending says nothing at all, which is most days. Workouts you
    /// already imported are ordinary notes, so they're in Notes and Folders like everything
    /// else — the list is only ever for the ones that haven't crossed over yet.
    private var healthNotice: Notice? {
        guard HealthKitService.isAvailable else { return nil }
        if !healthAccessAsked {
            guard !healthOfferDismissed else { return nil }
            return Notice(icon: "heart.text.square", tint: .red, action: .health, dismissible: true,
                          text: "Turn your workouts into notes, without typing them.")
        }
        guard unimportedActivity > 0 else { return nil }
        let what = unimportedActivity == 1 ? "One recent activity isn't" : "\(unimportedActivity) recent activities aren't"
        return Notice(icon: "figure.run", tint: .red, action: .health,
                      text: "\(what) in your notes yet.")
    }

    /// Count what's importable — only once Health is already connected, so this can never be
    /// the thing that triggers the permission sheet.
    private func countUnimportedActivity() async {
        healthAccessAsked = HealthKitService.accessRequested
        guard healthAccessAsked else { unimportedActivity = 0; return }
        let items = (try? await HealthKitService.fetch(daysBack: 14)) ?? []
        unimportedActivity = items.filter { model.healthNoteID(externalID: $0.id) == nil }.count
    }

    private func noticeList(_ notices: [Notice]) -> some View {
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
            if notice.action != .none {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).padding(.top, 3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())

        HStack(spacing: 0) {
            switch notice.action {
            case .none:
                row
            case .note(let id):
                Button { path.append(id) } label: { row }.buttonStyle(.plain)
            case .health:
                Button { showHealth = true } label: { row }.buttonStyle(.plain)
            }
            if notice.dismissible {
                // Tap it away and the offer never comes back; there is no second ask.
                Button { healthOfferDismissed = true } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(10)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .accessibilityLabel("Don't suggest this")
            }
        }
    }

    // MARK: - The rest of the app, kept quiet

    private var elsewhereLinks: some View {
        HStack(spacing: 22) {
            Button { showGuide = true } label: { Label("How it works", systemImage: "questionmark.circle") }
            Button { showCalendar = true } label: { Label("Calendar", systemImage: "calendar") }
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
