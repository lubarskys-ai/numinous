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
    /// Notices you've set aside, and when each becomes sayable again.
    @State private var ignoredUntil: [String: Date] = [:]

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
                        if !shown.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Numinous noticed")
                                    .font(.caption.weight(.semibold))
                                    .textCase(.uppercase)
                                    .kerning(0.8)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 4)
                                noticeList(shown)
                            }
                        }
                        elsewhereLinks
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 0)
                    .padding(.bottom, 96)   // clear of the floating tab bar
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { NoteDetailView(noteID: $0) }
        }
        // The digest walks every note, so build it when the data changes — not per render.
        .task(id: model.revision) {
            loadIgnored()
            digest = model.weeklyDigest()
            await countUnimportedActivity()
        }
        .fullScreenCover(isPresented: $showCompose) { ComposeView(prefillTitle: nil, autofocus: true) }
        .fullScreenCover(isPresented: $showAvatar) { AvatarExpandedView() }
        .sheet(isPresented: $showGuide) { GuideView() }
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
        var id: String { kind + "|" + text }
        /// Stable across wording changes, so ignoring "drifted from Sam — 3mo" doesn't come
        /// straight back as "drifted from Sam — 4mo".
        let kind: String
        let icon: String
        let tint: Color
        let text: String
        /// What tapping the row does about it. `.none` means there's nothing to open.
        var action: Action = .none
        /// What the action is called, so the row says what will happen rather than showing a
        /// bare chevron.
        var verb: String?
        /// How long "not now" holds. `nil` means never come back.
        var snooze: TimeInterval?

        init(kind: String, icon: String, tint: Color, text: String,
             action: Action = .none, verb: String? = nil, snooze: TimeInterval? = nil) {
            self.kind = kind; self.icon = icon; self.tint = tint; self.text = text
            self.action = action; self.verb = verb; self.snooze = snooze
        }
    }

    private static let day: TimeInterval = 86_400

    /// What you've set aside, and until when. Ignoring is a "not now", not a delete — a life
    /// you've drifted out of is worth raising again in a month.
    private static let ignoredKey = "home_notices_ignored"

    private func ignore(_ notice: Notice) {
        var until = ignoredUntil
        until[notice.kind] = Date().addingTimeInterval(notice.snooze ?? Self.day * 3650)
        ignoredUntil = until
        UserDefaults.standard.set(
            until.mapValues { $0.timeIntervalSince1970 }, forKey: Self.ignoredKey)
    }

    private func loadIgnored() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.ignoredKey) as? [String: Double] ?? [:]
        ignoredUntil = raw.compactMapValues { Date(timeIntervalSince1970: $0) }
            .filter { $0.value > Date() }          // expired ones simply come back
    }

    /// At most three, most-worth-saying first. Deliberately capped: a fourth line turns a
    /// landing into a feed, which is the thing this app is against.
    private var notices: [Notice] {
        guard let digest else { return [] }
        var out: [Notice] = []
        if let reflection = digest.reflection {
            out.append(Notice(kind: "reflection", icon: "sparkles", tint: .pink, text: reflection,
                              snooze: Self.day * 7))
        }
        if let nudge = digest.travelNudge {
            out.append(Notice(kind: "travel", icon: "globe.americas", tint: .teal, text: nudge,
                              snooze: Self.day * 30))
        }
        if let person = digest.drifting.first {
            let since = AppModel.outOfTouchLabel(person.lastContact).map { " — \($0)" } ?? ""
            out.append(Notice(kind: "drift:\(person.id)", icon: "heart", tint: .pink,
                              text: "You've drifted from \(person.name)\(since).",
                              action: .note(person.id), verb: "Open", snooze: Self.day * 30))
        }
        if let health = healthNotice {
            out.append(health)
        }
        if let quiet = digest.quietAxisIDs.first, let axis = model.axis(id: quiet) {
            out.append(Notice(kind: "quiet:\(quiet)", icon: "circle", tint: axis.color,
                              text: "\(axis.name) has been quiet this week.", snooze: Self.day * 7))
        }
        let now = Date()
        return Array(out.filter { (ignoredUntil[$0.kind] ?? .distantPast) < now }.prefix(3))
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
            return Notice(kind: "health-offer", icon: "heart.text.square", tint: .red,
                          text: "Turn your workouts into notes, without typing them.",
                          action: .health, verb: "Connect")   // no snooze — ignoring means never
        }
        guard unimportedActivity > 0 else { return nil }
        let what = unimportedActivity == 1 ? "One recent activity isn't" : "\(unimportedActivity) recent activities aren't"
        return Notice(kind: "health-pending", icon: "figure.run", tint: .red,
                      text: "\(what) in your notes yet.",
                      action: .health, verb: "Import", snooze: Self.day * 7)
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
                if i > 0 { Divider().padding(.leading, 48) }
                noticeRow(notice)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.secondary.opacity(0.15)))
        .animation(.easeInOut(duration: 0.22), value: notices.map(\.id))
    }

    @ViewBuilder
    /// A notice you can act on or set aside. Both are explicit: a named action rather than a
    /// bare chevron, and "Not now" rather than a silent swipe. Setting one aside is a pause,
    /// not a delete — each kind comes back after its own interval.
    private func noticeRow(_ notice: Notice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: notice.icon)
                    .font(.footnote)
                    .foregroundStyle(notice.tint)
                    .frame(width: 22)
                    .padding(.top, 2)
                Text(notice.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        if notice.snooze == nil { healthOfferDismissed = true }
                        ignore(notice)
                    }
                } label: {
                    Text(notice.snooze == nil ? "No thanks" : "Not now")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let verb = notice.verb, notice.action != .none {
                    Button { act(notice) } label: {
                        Text(verb)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(notice.tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(notice.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func act(_ notice: Notice) {
        switch notice.action {
        case .none:          break
        case .note(let id):  path.append(id)
        case .health:        showHealth = true
        }
    }

    // MARK: - The rest of the app, kept quiet

    private var elsewhereLinks: some View {
        HStack(spacing: 22) {
            Button { showGuide = true } label: { Label("How it works", systemImage: "questionmark.circle") }
        }
        .font(.subheadline)
        .padding(.top, 4)
    }

    /// Health was a tab; presented from Home it needs a way back out.
    private func closable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            content()
            Button { showHealth = false } label: {
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
