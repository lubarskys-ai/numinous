import SwiftUI
import NuminousCore

/// A "virtual file cabinet": each top-level category is a drawer you pull open,
/// then rifle through its files (notes) as a fanned, swipeable 2.5D deck — a
/// tactile alternative to the flat folder list.
struct CabinetView: View {
    @EnvironmentObject var model: AppModel
    var onOpenNote: (UUID) -> Void
    var onEditAxes: (String) -> Void
    var onBrowseFolder: (String) -> Void
    var onDeleteFolder: (String) -> Void
    var onRenameFolder: (String) -> Void
    var onMergeFolder: (String) -> Void
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
                               onOpenNote: onOpenNote,
                               onEditAxes: onEditAxes,
                               onBrowseFolder: onBrowseFolder,
                               onDeleteFolder: onDeleteFolder,
                               onRenameFolder: onRenameFolder,
                               onMergeFolder: onMergeFolder)
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
    @EnvironmentObject var model: AppModel
    let cabinet: CabinetView.Cabinet
    let isOpen: Bool
    let onToggle: () -> Void
    let onOpenNote: (UUID) -> Void
    let onEditAxes: (String) -> Void
    let onBrowseFolder: (String) -> Void
    let onDeleteFolder: (String) -> Void
    let onRenameFolder: (String) -> Void
    let onMergeFolder: (String) -> Void
    @State private var dropTarget: String?

    /// Above this many files a grid is unwieldy — show a peek + "Browse all".
    private let gridLimit = 18

    /// Handle a drop onto `folder`: a dropped note id (UUID string) moves that note here; a
    /// dropped folder path moves that whole folder in as a subfolder. Returns true if
    /// anything moved.
    private func handleDrop(_ items: [String], into folder: String) -> Bool {
        var moved = false
        for raw in items {
            if let id = UUID(uuidString: raw) {
                if model.moveNote(id, toFolder: folder) { moved = true }
            } else if model.moveFolder(raw, into: folder) {
                moved = true
            }
        }
        return moved
    }

    /// Immediate subfolder paths under this drawer's top category.
    private var subfolders: [String] {
        var seen = Set<String>(); var out: [String] = []
        let base = cabinet.id.lowercased() + "/"
        for n in cabinet.notes where n.folderName.lowercased().hasPrefix(base) {
            let rest = n.folderName.dropFirst(cabinet.id.count + 1)
            guard let seg = rest.split(separator: "/").first.map(String.init), !seg.isEmpty else { continue }
            let path = cabinet.id + "/" + seg
            if seen.insert(path.lowercased()).inserted { out.append(path) }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Notes filed directly in this drawer (not in a subfolder).
    private var directNotes: [Note] {
        cabinet.notes.filter { $0.folderName.lowercased() == cabinet.id.lowercased() }
    }

    private func descendantCount(_ path: String) -> Int {
        let p = path.lowercased()
        return cabinet.notes.filter { let fn = $0.folderName.lowercased(); return fn == p || fn.hasPrefix(p + "/") }.count
    }

    var body: some View {
        VStack(spacing: 0) {
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
                folderMenu
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
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: dropTarget == cabinet.id ? 2.5 : 0)
            )
            .shadow(color: .black.opacity(0.06), radius: 5, y: 3)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            // Drag a whole drawer onto another to move this category under it.
            .draggable(cabinet.id)
            .dropDestination(for: String.self) { items, _ in
                handleDrop(items, into: cabinet.id)
            } isTargeted: { hovering in
                dropTarget = hovering ? cabinet.id : (dropTarget == cabinet.id ? nil : dropTarget)
            }

            if isOpen {
                if cabinet.notes.isEmpty {
                    Text("No files yet").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    // Subfolders first (tap to drill into the hierarchical browser)…
                    if !subfolders.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(subfolders, id: \.self) { path in
                                Button { onBrowseFolder(path) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder.fill").foregroundStyle(cabinet.color)
                                        Text(path.split(separator: "/").last.map(String.init) ?? path)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(descendantCount(path))").font(.caption).foregroundStyle(.tertiary)
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 9).padding(.horizontal, 4).contentShape(Rectangle())
                                    .background(RoundedRectangle(cornerRadius: 8)
                                        .fill(dropTarget == path ? Color.accentColor.opacity(0.15) : .clear))
                                }
                                .buttonStyle(.plain)
                                .draggable(path)
                                .dropDestination(for: String.self) { items, _ in
                                    handleDrop(items, into: path)
                                } isTargeted: { hovering in
                                    dropTarget = hovering ? path : (dropTarget == path ? nil : dropTarget)
                                }
                            }
                        }
                        .padding(.top, 10)
                        .transition(.opacity)
                    }
                    // …then the notes filed directly here.
                    let shown = directNotes.count > gridLimit ? Array(directNotes.prefix(6)) : directNotes
                    if !shown.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(shown) { note in
                                MiniFileCard(note: note, color: cabinet.color)
                                    .onTapGesture { onOpenNote(note.id) }
                                    .draggable(note.id.uuidString)
                            }
                        }
                        .padding(.top, 12)
                        .transition(.opacity)
                    }
                    if directNotes.count > gridLimit || !subfolders.isEmpty {
                        Button { onBrowseFolder(cabinet.id) } label: {
                            Label("Browse all \(cabinet.notes.count), A–Z", systemImage: "list.bullet.indent")
                                .font(.callout.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(cabinet.color)
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    private var folderMenu: some View {
        Menu {
            Button { onEditAxes(cabinet.id) } label: { Label("Grows…", systemImage: "circle.hexagongrid") }
            Button { onRenameFolder(cabinet.id) } label: { Label("Rename or move folder…", systemImage: "folder") }
            Button { onMergeFolder(cabinet.id) } label: { Label("Merge into…", systemImage: "arrow.triangle.merge") }
            Menu("Default intensity") {
                let intensity = model.folder(named: cabinet.id)?.defaultIntensity
                Button { model.setFolderIntensity(nil, forFolder: cabinet.id) } label: {
                    if intensity == nil { Label("Neutral (3)", systemImage: "checkmark") } else { Text("Neutral (3)") }
                }
                ForEach(1...5, id: \.self) { level in
                    Button { model.setFolderIntensity(level, forFolder: cabinet.id) } label: {
                        if intensity == level { Label("⚡ \(level)", systemImage: "checkmark") } else { Text("⚡ \(level)") }
                    }
                }
            }
            Divider()
            Button(role: .destructive) { onDeleteFolder(cabinet.id) } label: {
                Label("Delete folder…", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(cabinet.color.opacity(0.7))
        }
    }
}

/// A single compact "file" card in the drawer grid: name, a short preview, and a
/// small colored dot. Tap to open. Small and uniform so many fit at a glance.
private struct MiniFileCard: View {
    let note: Note
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(note.isStub ? Color.secondary.opacity(0.5) : color).frame(width: 7, height: 7)
                Text(note.displayName)
                    .font(.caption.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
            }
            if let snippet {
                Text(snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            } else if note.isStub {
                Text("dormant").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(height: 92, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: .systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.16)))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
        .contentShape(Rectangle())
    }

    private var snippet: String? {
        let t = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.replacingOccurrences(of: "\n", with: " ")
    }
}
