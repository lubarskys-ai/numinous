import SwiftUI
import NuminousCore

/// The guided first capture — the very first thing a brand-new user sees instead of an
/// empty vault. Three warm prompts seed a person, a place, and a book/idea; Numinous
/// weaves them into a first entry so the connectome (and a few axes) come alive at once.
/// The reveal shows those axes lighting up — the reward is earned from what they just typed.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    @State private var person = ""
    @State private var place = ""
    @State private var interest = ""
    @State private var revealed: [Axis]?          // non-nil → show the "already alive" reveal
    @State private var shown = 0                   // how many axis chips have animated in
    @FocusState private var focus: Field?

    private enum Field { case person, place, interest }

    private var anyFilled: Bool {
        !(person + place + interest).trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack {
            background
            if let axes = revealed {
                reveal(axes)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                intake
                    .transition(.opacity)
            }
        }
    }

    // MARK: Background — a calm wash tinted by the growth axes.
    private var background: some View {
        LinearGradient(
            colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Axis.heart.color.opacity(0.10))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: 90, y: -120)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(Axis.meaning.color.opacity(0.10))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: -90, y: 120)
        }
    }

    // MARK: Intake
    private var intake: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Welcome to Numinous")
                        .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    Text("It grows from your life — not your attention. Plant the first few things and watch them begin to connect. You can change anything later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)

                VStack(spacing: 16) {
                    field("Someone you love", example: "Mom, Alex, an old friend…",
                          text: $person, field: .person, next: .place, axis: .heart)
                    field("A place that matters to you", example: "Grandma's kitchen, Central Park…",
                          text: $place, field: .place, next: .interest, axis: .meaning)
                    field("A book or idea that shaped you", example: "Meditations, stoicism, jazz…",
                          text: $interest, field: .interest, next: nil, axis: .mind)
                }

                Button(action: begin) {
                    Text("Plant these")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(anyFilled ? Color.accentColor : Color.gray.opacity(0.3),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(anyFilled ? Color.white : Color.secondary)
                }
                .disabled(!anyFilled)
                .padding(.top, 4)

                Button("I'll start on my own") { model.skipOnboarding() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func field(_ title: String, example: String, text: Binding<String>,
                       field: Field, next: Field?, axis: Axis) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(axis.color).frame(width: 8, height: 8)
                Text(title).font(.subheadline.weight(.medium))
            }
            TextField(example, text: text)
                .textFieldStyle(.plain)
                .padding(14)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                    focus == field ? axis.color.opacity(0.6) : Color.secondary.opacity(0.15), lineWidth: 1))
                .focused($focus, equals: field)
                .submitLabel(next == nil ? .done : .next)
                .onSubmit { focus = next }
                .autocorrectionDisabled(false)
        }
    }

    private func begin() {
        focus = nil
        let axes = model.completeOnboarding(person: person, place: place, interest: interest)
        withAnimation(.easeInOut(duration: 0.45)) { revealed = axes.isEmpty ? nil : axes }
        if axes.isEmpty { model.dismissOnboarding(); return }
        // Reveal the lit axes one at a time.
        for i in axes.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + Double(i) * 0.28) {
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
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("From three small things, your first connections have formed — and these parts of you are awake:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)

            HStack(spacing: 18) {
                ForEach(Array(axes.enumerated()), id: \.element.id) { idx, axis in
                    VStack(spacing: 8) {
                        ZStack {
                            Circle().fill(axis.color.opacity(0.18)).frame(width: 54, height: 54)
                            Circle().fill(axis.color).frame(width: 16, height: 16)
                                .shadow(color: axis.color.opacity(0.7), radius: 8)
                        }
                        Text(axis.name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .opacity(idx < shown ? 1 : 0)
                    .scaleEffect(idx < shown ? 1 : 0.6)
                }
            }
            .padding(.vertical, 34)

            Text("Keep tending them and a self takes shape — one you grow, not one you pose for.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button {
                model.dismissOnboarding()
            } label: {
                Text("Enter Numinous")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 30)
            .opacity(shown >= axes.count ? 1 : 0)
            .animation(.easeIn(duration: 0.4), value: shown)
        }
    }
}
