import SwiftUI
import NuminousCore

/// The guided first capture — a short, warm survey a brand-new user sees instead of an empty
/// vault. A few people, hobbies, and books/ideas; Numinous weaves them into a first entry so the
/// connectome comes alive at once — enough to look like a life beginning, not a toy.
///
/// NO AXES HERE. The first version named them: a coloured dot beside each field, and a reveal
/// that lit up Heart, Meaning and Mind as "parts of you now awake". It taught the app's private
/// vocabulary to somebody who had typed three names and could not yet want it — the reviewer's
/// "too complicated" in miniature. The axes still do all the same work; they are simply not the
/// first thing anybody is asked to understand. What the reveal shows now is the only thing that
/// is actually true to a newcomer: the things they named are already joined up.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    @State private var people: [String] = []
    @State private var hobbies: [String] = []
    @State private var books: [String] = []
    @State private var revealed = false            // true → show the "already alive" reveal
    @State private var arrived = false             // drives the reveal's one animation

    private var total: Int { people.count + hobbies.count + books.count }

    var body: some View {
        ZStack {
            background
            if revealed {
                reveal.transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                intake.transition(.opacity)
            }
        }
    }

    // MARK: Background — a calm wash tinted by the growth axes.
    private var background: some View {
        LinearGradient(colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Circle().fill(Color.accentColor.opacity(0.10)).frame(width: 320, height: 320)
                    .blur(radius: 80).offset(x: 90, y: -120)
            }
            .overlay(alignment: .bottomLeading) {
                Circle().fill(Color.accentColor.opacity(0.07)).frame(width: 300, height: 300)
                    .blur(radius: 80).offset(x: -90, y: 120)
            }
    }

    // MARK: Intake
    private var intake: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Let's plant a few roots")
                        .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    Text("Name a few of the things that make up your life — type one and press return, add as many or as few as you like. Numinous will start connecting them.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)

                CategoryField(title: "People who matter to you", example: "Mom, Alex, a mentor…",
                              items: $people)
                CategoryField(title: "Passions & hobbies", example: "hiking, cooking, guitar…",
                              items: $hobbies)
                CategoryField(title: "Books & ideas that shaped you", example: "Meditations, stoicism…",
                              items: $books)

                Button(action: begin) {
                    Text(total == 0 ? "Add a few to begin" : "Plant these \(total)")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(total > 0 ? Color.accentColor : Color.gray.opacity(0.3),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(total > 0 ? Color.white : Color.secondary)
                }
                .disabled(total == 0)
                .padding(.top, 4)

                Button("I'll start on my own") { model.skipOnboarding() }
                    .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func begin() {
        // The model still works out which axes these belong to — that is how a folder becomes
        // part of a life. The screen just no longer reports it.
        let planted = model.completeOnboarding(people: people, hobbies: hobbies, books: books)
        guard !planted.isEmpty else { model.dismissOnboarding(); return }
        withAnimation(.easeInOut(duration: 0.45)) { revealed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { arrived = true }
        }
    }

    // MARK: Reveal
    private var reveal: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Text("Your life is already taking shape.")
                    .font(.system(.title, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text("\(total) things planted, and Numinous has already started joining them up.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)

            // One quiet mark that something happened, rather than a row of chips naming machinery
            // nobody has been introduced to yet.
            ZStack {
                Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                    .frame(width: 118, height: 118)
                    .scaleEffect(arrived ? 1 : 0.7).opacity(arrived ? 1 : 0)
                Circle().fill(Color.accentColor.opacity(0.14)).frame(width: 74, height: 74)
                    .scaleEffect(arrived ? 1 : 0.5)
                Text("\(total)")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(arrived ? 1 : 0)
            }
            .padding(.vertical, 34)

            Text("Keep tending them and a self takes shape — one you grow, not one you pose for.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)

            Spacer()

            Button { model.dismissOnboarding() } label: {
                Text("Enter Numinous").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 26).padding(.bottom, 30)
            .opacity(arrived ? 1 : 0)
            .animation(.easeIn(duration: 0.4), value: arrived)
        }
    }
}

// MARK: - One survey category: a labeled field that collects several items as chips.
private struct CategoryField: View {
    let title: String
    let example: String
    @Binding var items: [String]
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)").font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            if !items.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(items, id: \.self) { item in chip(item) }
                }
            }
            TextField(example, text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
                .padding(12)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(
                    focused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15), lineWidth: 1))
        }
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        draft = ""
        guard !t.isEmpty, items.count < 8,
              !items.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        items.append(t)
    }

    private func chip(_ item: String) -> some View {
        HStack(spacing: 6) {
            Text(item).font(.subheadline)
            Button { items.removeAll { $0 == item } } label: {
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
    }
}

// MARK: - A simple wrapping flow layout for the chips (iOS 16+ Layout).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
