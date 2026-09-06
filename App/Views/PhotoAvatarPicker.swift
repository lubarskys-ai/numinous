import PhotosUI
import SwiftUI

/// Choosing the photograph, and saying which of the people in it is you.
///
/// Two steps, and the second one only appears when it has to. A photo of one person needs no
/// question asked; a photo of two people needs exactly one tap, and never a guess — the whole
/// point is that your partner stays sharp while you dissolve.
struct PhotoAvatarPicker: View {
    @Environment(\.dismiss) private var dismiss
    var onSaved: () -> Void

    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var people: [(index: Int, centre: CGPoint)] = []
    @State private var chosen: Int?
    @State private var busyBackground = false
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let image {
                    GeometryReader { geo in
                        ZStack {
                            Image(uiImage: image).resizable().scaledToFit()
                            // One tap target per person, over their neck.
                            ForEach(people, id: \.index) { person in
                                let fitted = fit(image.size, in: geo.size)
                                Button {
                                    chosen = person.index
                                } label: {
                                    Circle()
                                        .strokeBorder(chosen == person.index ? Color.accentColor : .white,
                                                      lineWidth: chosen == person.index ? 4 : 2)
                                        .background(Circle().fill(.black.opacity(0.25)))
                                        .frame(width: 44, height: 44)
                                }
                                .position(x: fitted.origin.x + person.centre.x * fitted.width,
                                          y: fitted.origin.y + (1 - person.centre.y) * fitted.height)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .frame(maxHeight: 420)

                    if people.count > 1 {
                        Text(chosen == nil ? "Tap yourself." : "That's you.")
                            .font(.headline)
                    }
                    if busyBackground {
                        Label("This background is busy, so where you stood will read as a soft "
                              + "shadow rather than disappearing. A plainer wall or sky erases cleanly.",
                              systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, 24).multilineTextAlignment(.leading)
                    }
                } else {
                    ContentUnavailableView(
                        "Choose the best version of you",
                        systemImage: "person.crop.square",
                        description: Text("A photo where you're standing clear of the background, "
                                          + "head to foot. You'll be taken out of it, and come back "
                                          + "as you live."))
                }

                PhotosPicker(image == nil ? "Choose a photo" : "Choose a different photo",
                             selection: $item, matching: .images)
                    .buttonStyle(.borderedProminent)

                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                        .padding(.horizontal, 24).multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            .navigationTitle("Your photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this") { use() }
                        .disabled(image == nil || working || (people.count > 1 && chosen == nil))
                }
            }
            .overlay { if working { ProgressView().controlSize(.large) } }
            .onChange(of: item) { _, new in Task { await load(new) } }
        }
    }

    private func fit(_ size: CGSize, in box: CGSize) -> CGRect {
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    private func load(_ new: PhotosPickerItem?) async {
        guard let data = try? await new?.loadTransferable(type: Data.self),
              let raw = UIImage(data: data) else { return }
        // Straightened before it is shown, so what you tap and what the app measured are the
        // same picture. Showing the original and measuring the rotated one is how the tap
        // targets ended up beside the person instead of on them.
        let picked = PhotoAvatar.upright(raw)
        image = picked
        chosen = nil
        problem = nil
        people = (try? PhotoAvatar.people(in: picked)) ?? []
        if people.count == 1 { chosen = people[0].index }
        if people.isEmpty { problem = PhotoAvatar.whyNoOneFound() }
    }

    private func use() {
        guard let image else { return }
        working = true
        let index = chosen ?? 0
        Task {
            defer { working = false }
            do {
                let prepared = try PhotoAvatar.prepare(image: image, personIndex: index)
                busyBackground = prepared.backgroundIsBusy
                try PhotoAvatar.save(prepared)
                onSaved()
                dismiss()
            } catch {
                problem = "Couldn't prepare that photo. Try another."
            }
        }
    }
}
