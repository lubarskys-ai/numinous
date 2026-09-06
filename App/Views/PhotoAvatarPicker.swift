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
    @State private var cleanItem: PhotosPickerItem?
    @State private var cleanImage: UIImage?
    @State private var people: [(index: Int, centre: CGPoint)] = []
    @State private var chosen: CGPoint?
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
                                    chosen = person.centre
                                    checkBackground()
                                } label: {
                                    Circle()
                                        .strokeBorder(chosen == person.centre ? Color.accentColor : .white,
                                                      lineWidth: chosen == person.centre ? 4 : 2)
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
                    if busyBackground && cleanImage == nil {
                        Label("This background has a lot of detail, so where you stood will not "
                              + "erase cleanly. Either pick a photo with more plain wall or sky "
                              + "behind you — or duplicate this one in Photos, erase yourself "
                              + "with Clean Up, and add it below. You only ever do that once.",
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

                // THE BEST ERASURE AVAILABLE IS THE ONE ON THE PHONE ALREADY, and it belongs
                // to the Photos app. Apple's Clean Up reconstructs what was behind you instead
                // of borrowing from beside you, and no amount of arithmetic here matches it —
                // but it is not offered to other apps, so it cannot be called. It can be
                // handed the result, which takes one minute, once, and is then perfect forever.
                if image != nil {
                    VStack(spacing: 8) {
                        PhotosPicker(cleanImage == nil
                                     ? "Add the same photo with yourself erased (optional)"
                                     : "Erased version added ✓",
                                     selection: $cleanItem, matching: .images)
                        Text("For a flawless result: duplicate this photo in Photos, use "
                             + "**Clean Up** to erase yourself, and add it here. Numinous will "
                             + "use it as the background instead of filling the gap itself.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 28)
                    }
                }

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
            .onChange(of: cleanItem) { _, new in
                Task {
                    guard let data = try? await new?.loadTransferable(type: Data.self),
                          let picked = UIImage(data: data) else { return }
                    cleanImage = PhotoAvatar.upright(picked)
                }
            }
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
        cleanImage = nil
        cleanItem = nil
        chosen = nil
        problem = nil
        people = (try? PhotoAvatar.people(in: picked)) ?? []
        if people.count == 1 { chosen = people[0].centre; checkBackground() }
        if people.isEmpty { problem = PhotoAvatar.whyNoOneFound() }
    }

    /// Look at the ground behind whoever was tapped, while there is still time to act on it.
    private func checkBackground() {
        guard let image, let youAt = chosen else { return }
        Task { busyBackground = PhotoAvatar.backgroundWillSmear(image, youAt: youAt) }
    }

    private func use() {
        guard let image else { return }
        working = true
        let youAt = chosen ?? CGPoint(x: 0.5, y: 0.5)
        Task {
            defer { working = false }
            do {
                let prepared = try PhotoAvatar.prepare(image: image, youAt: youAt,
                                                       cleanBackground: cleanImage)
                try PhotoAvatar.save(prepared)
                onSaved()
                dismiss()
            } catch {
                problem = "Couldn't prepare that photo. Try another."
            }
        }
    }
}
