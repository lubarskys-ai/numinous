import SwiftUI
import NuminousCore

/// The guided first capture — a short, warm survey a brand-new user sees instead of an empty
/// vault. A few people, hobbies, and books/ideas; Numinous weaves them into a first entry so
/// the connectome (and several axes) come alive at once — enough to look like a life beginning,
/// not a toy. The reveal shows those axes lighting up, earned from what they just entered.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    @State private var people: [String] = []
    @State private var hobbies: [String] = []
    @State private var books: [String] = []
    @State private var revealed: [Axis]?          // non-nil → show the "already alive" reveal
    @State private var shown = 0                   // how many axis chips have animated in

    private var total: Int { people.count + hobbies.count + books.count }

    var body: some View {
        ZStack {
            background
            if let axes = revealed {
                reveal(axes).transition(.opacity.combined(with: .move(edge: .trailing)))
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
                Circle().fill(Axis.heart.color.opacity(0.10)).frame(width: 320, height: 320)
                    .blur(radius: 80).offset(x: 90, y: -120)
            }
            .overlay(alignment: .bottomLeading) {
                Circle().fill(Axis.meaning.color.opacity(0.10)).frame(width: 300, height: 300)
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
                              axis: .heart, items: $people)
                CategoryField(title: "Passions & hobbies", example: "hiking, cooking, guitar…",
                              axis: .meaning, items: $hobbies)
                CategoryField(title: "Books & ideas that shaped you", example: "Meditations, stoicism…",
                              axis: .mind, items: $books)

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
        let axes = model.completeOnboarding(people: people, hobbies: hobbies, books: books)
        withAnimation(.easeInOut(duration: 0.45)) { revealed = axes.isEmpty ? nil : axes }
        if axes.isEmpty { model.dismissOnboarding(); return }
        for i in axes.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + Double(i) * 0.26) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { shown = i + 1 }
            }
        }
    }

    // MARK: Reveal
    private func reveal(_ axes: [Axis]) -> some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Text("Your life is already taking shape.")
                    .font(.system(.title, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text("From \(total) small things, your first connections have formed — and these parts of you are awake:")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)

            HStack(spacing: 16) {
                ForEach(Array(axes.enumerated()), id: \.element.id) { idx, axis in
                    VStack(spacing: 8) {
                        ZStack {
                            Circle().fill(axis.color.opacity(0.18)).frame(width: 52, height: 52)
                            Circle().fill(axis.color).frame(width: 15, height: 15)
                                .shadow(color: axis.color.opacity(0.7), radius: 8)
                        }
                        Text(axis.name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .opacity(idx < shown ? 1 : 0)
                    .scaleEffect(idx < shown ? 1 : 0.6)
                }
            }
            .padding(.vertical, 32)

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
            .opacity(shown >= axes.count ? 1 : 0)
            .animation(.easeIn(duration: 0.4), value: shown)
        }
    }
}

// MARK: - One survey category: a labeled field that collects several items as chips.
private struct CategoryField: View {
    let title: String
    let example: String
    let axis: Axis
    @Binding var items: [String]
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(axis.color).frame(width: 8, height: 8)
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)").font(.caption.weight(.medium)).foregroundStyle(axis.color)
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
                    focused ? axis.color.opacity(0.6) : Color.secondary.opacity(0.15), lineWidth: 1))
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
        .background(axis.color.opacity(0.14), in: Capsule())
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
