import SwiftUI
import NuminousCore

/// A "virtual file cabinet": each top-level category is a drawer you pull open,
/// then rifle through its files (notes) as a fanned, swipeable 2.5D deck — a
/// tactile alternative to the flat folder list.
struct CabinetView: View {
    @EnvironmentObject var model: AppModel
    var onOpenNote: (UUID) -> Void
    @State private var openCategory: String?

    struct Cabinet: Identifiable {
        let id: String
        var name: String { id }
        let notes: [Note]
        let color: Color
        let symbol: String
    }

    private var cabinets: [Cabinet] {
        var groups: [String: [Note]] = [:]
        for note in model.notes {
            let top = note.folderName.split(separator: "/").first.map(String.init) ?? ""
            guard !top.isEmpty else { continue }
            groups[top, default: []].append(note)
        }
        return groups.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { key in
                let notes = (groups[key] ?? []).sorted { $0.date > $1.date }
                let folder = model.folder(named: key)
                let axis = model.axis(id: folder?.axisID) ?? notes.lazy.compactMap { model.axis(for: $0) }.first
                return Cabinet(id: key, notes: notes,
                               color: axis?.color ?? .secondary,
                               symbol: folderSymbol(key, folder?.category))
            }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(cabinets) { cab in
                    DrawerView(cabinet: cab, isOpen: openCategory == cab.id,
                               onToggle: {
                                   withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                       openCategory = openCategory == cab.id ? nil : cab.id
                                   }
                               },
                               onOpenNote: onOpenNote)
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 130)
        }
    }
}

/// One drawer: a pull-able face that, when open, reveals the riffle deck.
private struct DrawerView: View {
    let cabinet: CabinetView.Cabinet
    let isOpen: Bool
    let onToggle: () -> Void
    let onOpenNote: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    AxisIconTile(symbol: cabinet.symbol, color: cabinet.color, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cabinet.name)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(cabinet.notes.count) file\(cabinet.notes.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.body.weight(.semibold)).foregroundStyle(cabinet.color.opacity(0.7))
                }
                .padding(.horizontal, 16)
                .padding(.top, 16).padding(.bottom, 20)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [Color(uiColor: .secondarySystemBackground),
                                                      cabinet.color.opacity(0.10)],
                                             startPoint: .top, endPoint: .bottom))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(cabinet.color.opacity(0.18))
                )
                .overlay(alignment: .bottom) {
                    Capsule().fill(cabinet.color.opacity(0.4)).frame(width: 44, height: 4).padding(.bottom, 7)
                }
                .shadow(color: .black.opacity(0.06), radius: 5, y: 3)
            }
            .buttonStyle(.plain)

            if isOpen {
                RiffleDeck(notes: cabinet.notes, color: cabinet.color, onOpenNote: onOpenNote)
                    .frame(height: 250)
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// The files of one drawer, fanned in depth. Swipe to rifle through; tap the
/// front file to open it.
private struct RiffleDeck: View {
    let notes: [Note]
    let color: Color
    let onOpenNote: (UUID) -> Void
    @State private var index = 0
    @GestureState private var dragX: CGFloat = 0

    var body: some View {
        if notes.isEmpty {
            Text("No files yet").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            GeometryReader { geo in
                ZStack {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { pair in
                        let rel = Double(pair.offset) - Double(index) - Double(dragX / 150)
                        if abs(rel) < 3.4 {
                            FileCard(note: pair.element, color: color)
                                .frame(width: geo.size.width * 0.72, height: 208)
                                .scaleEffect(1 - min(0.28, abs(rel) * 0.08))
                                .offset(x: CGFloat(rel) * 48, y: CGFloat(abs(rel)) * 7)
                                .rotation3DEffect(.degrees(rel * -13), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                                .opacity(rel < -1.7 ? 0 : 1)
                                .zIndex(-abs(rel))
                                .onTapGesture {
                                    if pair.offset == index { onOpenNote(pair.element.id) }
                                    else { withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { index = pair.offset } }
                                }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($dragX) { value, state, _ in state = value.translation.width }
                        .onEnded { value in
                            let step = Int((-value.translation.width / 110).rounded())
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                                index = max(0, min(notes.count - 1, index + step))
                            }
                        }
                )
            }
        }
    }
}

/// A single "file": a hanging-file card with a colored tab.
private struct FileCard: View {
    let note: Note
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tab)
                .font(.caption2.weight(.semibold)).foregroundStyle(color)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(color.opacity(0.18), in: Capsule())
            Text(note.displayName)
                .font(.system(.title3, design: .rounded).weight(.semibold)).lineLimit(2)
            if let snippet { Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(4) }
            Spacer(minLength: 0)
            if note.isStub {
                Label("dormant", systemImage: "moon.zzz").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("\(note.intensity)", systemImage: "bolt.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.opacity(0.22)))
        .shadow(color: .black.opacity(0.14), radius: 9, y: 5)
    }

    private var tab: String {
        note.folderName.contains("/") ? String(note.folderName.split(separator: "/").last!) : note.folderName
    }

    private var snippet: String? {
        let t = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.replacingOccurrences(of: "\n", with: " ")
    }
}
