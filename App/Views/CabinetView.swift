import SwiftUI
import UniformTypeIdentifiers
import NuminousCore

/// Multi-select state for the Folders tab: whether selection mode is on, and which
/// notes and whole folders are picked. Shared by the tab and its drawers.
struct FolderSelection {
    var active = false
    var notes: Set<UUID> = []
    var folders: Set<String> = []
    var isEmpty: Bool { notes.isEmpty && folders.isEmpty }
    var count: Int { notes.count + folders.count }
    mutating func toggleNote(_ id: UUID) { if !notes.insert(id).inserted { notes.remove(id) } }
    mutating func toggleFolder(_ path: String) { if !folders.insert(path).inserted { folders.remove(path) } }
    mutating func clear() { notes.removeAll(); folders.removeAll() }
}

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
    var onMoveNote: (UUID) -> Void
    @Binding var selection: FolderSelection
    @State private var openCategory: String?

    struct Cabinet: Identifiable {
        let id: String
        var name: String { id }
        let notes: [Note]
        let color: Color
        let symbol: String
    }

    /// When this app binary was built/installed — shown at the bottom of the cabinet so you
    /// can confirm the device actually got the newest build.
    static var buildStamp: String {
        let date = (try? FileManager.default.attributesOfItem(atPath: Bundle.main.executablePath ?? "")[.modificationDate]) as? Date
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return "Build: " + (date.map { f.string(from: $0) } ?? "unknown")
    }

    /// Reads the model's cached grouping (recomputed only when notes change, not per
    /// render) and just decorates each group with its axis color/symbol — cheap, since
    /// there are only a handful of top-level cabinets.
    private var cabinets: [Cabinet] {
        let t0 = CFAbsoluteTimeGetCurrent()
        let result = model.cabinetGroups.map { group in
            let folder = model.folder(named: group.id)
            let axis = model.axis(id: folder?.axisID) ?? group.notes.lazy.compactMap { model.axis(for: $0) }.first
            return Cabinet(id: group.id, notes: group.notes,
                           color: axis?.color ?? .secondary,
                           symbol: folderSymbol(group.id, folder?.category))
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if ms > 20 { print("⏱️[perf] cabinets \(Int(ms))ms count=\(result.count)") }
        return result
    }

    var body: some View {
        ScrollView {
            // Lazy so off-screen drawers (each with a context menu, drag & drop targets)
            // don't all render eagerly — matters when a big import creates many folders.
            LazyVStack(spacing: 12) {
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
                               onMergeFolder: onMergeFolder,
                               onMoveNote: onMoveNote,
                               selection: $selection)
                }
                // A visible build stamp so you can confirm your phone is running the
                // latest install (if this doesn't change after a rebuild, the new build
                // didn't reach the device).
                Text(Self.buildStamp)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.top, 10)
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
    let onMoveNote: (UUID) -> Void
    @Binding var selection: FolderSelection
    @State private var dropTarget: String?
    @State private var renameID: UUID?
    @State private var renameDraft = ""
    @State private var deleteID: UUID?
    @State private var cleanupConfirm = false
    @State private var dupConfirm = false

    /// The action menu shared by a note card's ⋯ button and its long-press — the same
    /// Open · Rename · Move · Delete offered in the folder browser.
    @ViewBuilder private func noteMenu(_ note: Note) -> some View {
        noteActionButtons(
            open: { onOpenNote(note.id) },
            rename: { renameDraft = note.displayName; renameID = note.id },
            move: { onMoveNote(note.id) },
            delete: { deleteID = note.id }
        )
    }

    /// Above this many files a grid is unwieldy — show a peek + "Browse all".
    private let gridLimit = 18

    /// Handle a drop onto `folder` using the classic NSItemProvider API (reliable on a
    /// physical device, unlike `.dropDestination(for: String.self)`, which can deliver an
    /// empty payload there). Each provider carries a note id (UUID string → move that note)
    /// or a folder path (→ move that whole folder in). The load is async, so we apply the
    /// move back on the main actor. Returns whether we accepted the drop.
    private func handleDrop(_ providers: [NSItemProvider], into folder: String) -> Bool {
        let usable = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !usable.isEmpty else { return false }
        for p in usable {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let raw = obj as? String else { return }
                let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { return }
                Task { @MainActor in
                    if let id = UUID(uuidString: s) {
                        model.moveNote(id, toFolder: folder)
                    } else {
                        model.moveFolder(s, into: folder)
                    }
                }
            }
        }
        return true
    }

    /// Immediate subfolders under this drawer's top category, each with its descendant
    /// count — computed in ONE pass over the drawer's notes (was O(subfolders × notes)
    /// because the count was recomputed per row every render).
    private var subfolderRows: [(path: String, count: Int)] {
        let _t0 = CFAbsoluteTimeGetCurrent()
        defer { let ms = (CFAbsoluteTimeGetCurrent() - _t0) * 1000
            if ms > 20 { print("⏱️[perf] subfolderRows \(Int(ms))ms cabinet=\(cabinet.id) notes=\(cabinet.notes.count)") } }
        let base = cabinet.id.lowercased() + "/"
        var counts: [String: Int] = [:]      // lowercased subfolder path → count
        var casing: [String: String] = [:]   // lowercased → original casing
        for n in cabinet.notes where n.folderName.lowercased().hasPrefix(base) {
            let rest = n.folderName.dropFirst(cabinet.id.count + 1)
            guard let seg = rest.split(separator: "/").first.map(String.init), !seg.isEmpty else { continue }
            let path = cabinet.id + "/" + seg
            let key = path.lowercased()
            if casing[key] == nil { casing[key] = path }
            counts[key, default: 0] += 1
        }
        return counts.keys
            .sorted { casing[$0]!.localizedCaseInsensitiveCompare(casing[$1]!) == .orderedAscending }
            .map { (path: casing[$0]!, count: counts[$0]!) }
    }

    /// Notes filed directly in this drawer (not in a subfolder).
    private var directNotes: [Note] {
        cabinet.notes.filter { $0.folderName.lowercased() == cabinet.id.lowercased() }
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
                if selection.active {
                    Image(systemName: selection.folders.contains(cabinet.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title2).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(selection.folders.contains(cabinet.id) ? cabinet.color : Color.secondary)
                } else {
                    folderMenu
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.body.weight(.semibold)).foregroundStyle(cabinet.color.opacity(0.7))
                }
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
            .onTapGesture { if selection.active { selection.toggleFolder(cabinet.id) } else { onToggle() } }
            // Long-press the folder header for the same Rename / Move / Merge / Delete
            // actions as the ⋯ button (only outside select mode).
            .contextMenu { if !selection.active { folderMenuContent } }
            // Drag a whole drawer onto another to move this category under it.
            .onDrag { NSItemProvider(object: cabinet.id as NSString) }

            if isOpen {
                if cabinet.notes.isEmpty {
                    Text("No files yet").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    // Subfolders first (tap to drill into the hierarchical browser)…
                    if !subfolderRows.isEmpty {
                        LazyVStack(spacing: 2) {
                            ForEach(subfolderRows, id: \.path) { row in
                                let path = row.path
                                Button { if selection.active { selection.toggleFolder(path) } else { onBrowseFolder(path) } } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder.fill").foregroundStyle(cabinet.color)
                                        Text(path.split(separator: "/").last.map(String.init) ?? path)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(row.count)").font(.caption).foregroundStyle(.tertiary)
                                        if selection.active {
                                            Image(systemName: selection.folders.contains(path) ? "checkmark.circle.fill" : "circle")
                                                .symbolRenderingMode(.hierarchical)
                                                .foregroundStyle(selection.folders.contains(path) ? cabinet.color : Color.secondary)
                                        } else {
                                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                    }
                                    .padding(.vertical, 9).padding(.horizontal, 4).contentShape(Rectangle())
                                    .background(RoundedRectangle(cornerRadius: 8)
                                        .fill(dropTarget == path ? Color.accentColor.opacity(0.15) : .clear))
                                }
                                .buttonStyle(.plain)
                                .contextMenu { if !selection.active { subfolderMenu(path) } }
                                .onDrag { NSItemProvider(object: path as NSString) }
                                .onDrop(of: [.text], isTargeted: Binding(
                                    get: { dropTarget == path },
                                    set: { dropTarget = $0 ? path : (dropTarget == path ? nil : dropTarget) }
                                )) { providers in
                                    handleDrop(providers, into: path)
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
                                MiniFileCard(note: note, color: cabinet.color,
                                             selected: selection.active && selection.notes.contains(note.id))
                                    .onTapGesture {
                                        if selection.active { selection.toggleNote(note.id) } else { onOpenNote(note.id) }
                                    }
                                    // In select mode: a checkmark. Otherwise a one-tap menu
                                    // (no long-press needed) — the reliable way to move a note
                                    // to a far folder without dragging through a slow scroll.
                                    .overlay(alignment: .topTrailing) {
                                        if selection.active {
                                            Image(systemName: selection.notes.contains(note.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.title3).symbolRenderingMode(.hierarchical)
                                                .foregroundStyle(selection.notes.contains(note.id) ? cabinet.color : Color.secondary)
                                                .padding(6)
                                        } else {
                                            Menu { noteMenu(note) } label: {
                                                Image(systemName: "ellipsis.circle.fill")
                                                    .font(.body)
                                                    .symbolRenderingMode(.hierarchical)
                                                    .foregroundStyle(cabinet.color.opacity(0.7))
                                                    .padding(6)
                                                    .contentShape(Rectangle())
                                            }
                                            .accessibilityLabel("Note actions")
                                        }
                                    }
                                    .onDrag { NSItemProvider(object: note.id.uuidString as NSString) }
                                    .contextMenu { if !selection.active { noteMenu(note) } }
                            }
                        }
                        .padding(.top, 12)
                        .transition(.opacity)
                    }
                    if directNotes.count > gridLimit || !subfolderRows.isEmpty {
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
        // The WHOLE drawer is the drop target (not just the header), so a note or folder
        // dropped anywhere on an open drawer lands instead of snapping back to where it
        // started. Subfolder rows above keep their own, more-specific drop zones.
        .onDrop(of: [.text], isTargeted: Binding(
            get: { dropTarget == cabinet.id },
            set: { dropTarget = $0 ? cabinet.id : (dropTarget == cabinet.id ? nil : dropTarget) }
        )) { providers in
            handleDrop(providers, into: cabinet.id)
        }
        .alert("Rename note", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let id = renameID, let n = model.note(id: id) {
                    let leaf = renameDraft.trimmingCharacters(in: .whitespaces)
                    if !leaf.isEmpty {
                        model.renameNote(id, to: n.folderName.isEmpty ? leaf : n.folderName + "/" + leaf)
                    }
                }
            }
        }
        .confirmationDialog("Delete this note?",
                            isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = deleteID, let n = model.note(id: id) { model.delete([n]) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the note. It can't be undone.")
        }
        .confirmationDialog("Remove unlinked notes?", isPresented: $cleanupConfirm, titleVisibility: .visible) {
            let doomed = model.unlinkedNotes(inFolder: cabinet.id)
            Button("Remove \(doomed.count) note\(doomed.count == 1 ? "" : "s")", role: .destructive) {
                model.delete(doomed)
            }
            .disabled(doomed.isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            let c = model.unlinkedNotes(inFolder: cabinet.id).count
            if c == 0 {
                Text("Every note in “\(cabinet.name)” is linked to something — nothing to remove.")
            } else {
                Text("\(c) note\(c == 1 ? "" : "s") in “\(cabinet.name)” link to nothing and nothing links to them. Keeps only connected notes. This can't be undone.")
            }
        }
        .confirmationDialog("Merge duplicates?", isPresented: $dupConfirm, titleVisibility: .visible) {
            let n = model.mergeableDuplicateCount(inFolder: cabinet.id)
            Button(n > 0 ? "Merge \(n) duplicate\(n == 1 ? "" : "s")" : "Merge duplicates") {
                model.mergeDuplicatesAndDedupe(inFolder: cabinet.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let c = model.mergeableDuplicateCount(inFolder: cabinet.id)
            if c == 0 {
                Text("No duplicates detected in “\(cabinet.name)”. Merging will still tidy any exact same-name copies elsewhere.")
            } else {
                Text("\(c) note\(c == 1 ? "" : "s") duplicate an existing note — either named like “… (2)” or sharing the same name. Their contents are merged into the original and the copies removed — nothing is lost. This can't be undone.")
            }
        }
    }

    /// Actions for a whole folder — shown both from the ⋯ button and by long-pressing
    /// the folder header, so a click-and-hold gives Rename / Move / Merge / Delete.
    @ViewBuilder private var folderMenuContent: some View {
        Button { onRenameFolder(cabinet.id) } label: { Label("Rename or move folder…", systemImage: "pencil") }
        Button { onMergeFolder(cabinet.id) } label: { Label("Merge into…", systemImage: "arrow.triangle.merge") }
        Button { onEditAxes(cabinet.id) } label: { Label("Grows…", systemImage: "circle.hexagongrid") }
        Button { cleanupConfirm = true } label: { Label("Remove unlinked notes…", systemImage: "sparkles") }
        Button { dupConfirm = true } label: { Label("Merge duplicates…", systemImage: "arrow.triangle.merge") }
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
    }

    private var folderMenu: some View {
        Menu { folderMenuContent } label: {
            Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(cabinet.color.opacity(0.7))
        }
    }

    /// Long-press actions for a subfolder row (a folder nested inside this drawer).
    @ViewBuilder private func subfolderMenu(_ path: String) -> some View {
        Button { onBrowseFolder(path) } label: { Label("Open", systemImage: "folder") }
        Button { onRenameFolder(path) } label: { Label("Rename or move folder…", systemImage: "pencil") }
        Button { onMergeFolder(path) } label: { Label("Merge into…", systemImage: "arrow.triangle.merge") }
        Divider()
        Button(role: .destructive) { onDeleteFolder(path) } label: { Label("Delete folder…", systemImage: "trash") }
    }
}

/// A single compact "file" card in the drawer grid: name, a short preview, and a
/// small colored dot. Tap to open. Small and uniform so many fit at a glance.
private struct MiniFileCard: View {
    let note: Note
    let color: Color
    var selected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(note.isStub ? Color.secondary.opacity(0.5) : color).frame(width: 7, height: 7)
                Text(note.displayName)
                    .font(.caption.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
            }
            .padding(.trailing, 18)   // leave room for the actions menu in the corner
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
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? color.opacity(0.12) : Color(uiColor: .systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? color : color.opacity(0.16), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
        .contentShape(Rectangle())
    }

    private var snippet: String? {
        let t = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.replacingOccurrences(of: "\n", with: " ")
    }
}
