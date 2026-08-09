import SwiftUI
import MapKit
import NuminousCore

/// A map of where your life happened: every note place that has coordinates, plotted
/// and colored by its axis. Tap a pin to open the note. The dataset is narrowed by
/// pre-selected filters — a folder and a time period — so you can look at just your
/// travels, just this year, just people, etc. Older text-only locations are geocoded
/// in the background so they show up too.
struct MapView: View {
    @EnvironmentObject var model: AppModel

    /// The time windows you can slice the map by.
    enum Period: String, CaseIterable, Identifiable {
        case all = "All time"
        case year = "This year"
        case month = "This month"
        case days30 = "Past 30 days"
        var id: String { rawValue }
        func contains(_ date: Date) -> Bool {
            let cal = Calendar.current
            switch self {
            case .all:    return true
            case .year:   return cal.isDate(date, equalTo: Date(), toGranularity: .year)
            case .month:  return cal.isDate(date, equalTo: Date(), toGranularity: .month)
            case .days30: return date >= (cal.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast)
            }
        }
    }

    @State private var folder: String? = nil          // nil = all folders
    @State private var period: Period = .all
    @State private var position: MapCameraPosition = .automatic
    @State private var openNote: NoteRef?
    @State private var geocodedOnce = false

    private struct NoteRef: Identifiable { let id: UUID }

    private struct Pin: Identifiable {
        let id = UUID()
        let noteID: UUID
        let title: String
        let coordinate: CLLocationCoordinate2D
        let color: Color
    }

    /// Notes matching the current filters, expanded to one pin per coordinate-bearing place.
    private var pins: [Pin] {
        var out: [Pin] = []
        for n in model.notes {
            guard folderMatches(n), period.contains(n.date) else { continue }
            let color = model.axis(for: n)?.color ?? .red
            for p in n.allPlaces where p.hasCoordinate {
                out.append(Pin(noteID: n.id, title: n.displayName,
                               coordinate: CLLocationCoordinate2D(latitude: p.latitude!, longitude: p.longitude!),
                               color: color))
            }
        }
        return out
    }

    private func folderMatches(_ n: Note) -> Bool {
        guard let folder else { return true }
        let f = n.folderName.lowercased(), sel = folder.lowercased()
        return f == sel || f.hasPrefix(sel + "/")
    }

    /// Distinct top-level folders that actually contain notes, for the folder filter.
    private var topFolders: [String] {
        var seen = Set<String>(); var out: [String] = []
        for n in model.notes {
            let top = n.folderName.split(separator: "/").first.map(String.init) ?? ""
            if !top.isEmpty, seen.insert(top.lowercased()).inserted { out.append(top) }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                ForEach(pins) { pin in
                    Annotation(pin.title, coordinate: pin.coordinate) {
                        Button { openNote = NoteRef(id: pin.noteID) } label: {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, pin.color)
                                .shadow(radius: 1.5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .overlay(alignment: .top) { filterBar }
            .overlay { if pins.isEmpty { emptyState } }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $openNote) { ref in
                NavigationStack { NoteDetailView(noteID: ref.id) }
            }
            .task { await backfillGeocoding() }
            .onChange(of: folder) { position = .automatic }
            .onChange(of: period) { position = .automatic }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button { folder = nil } label: { filterCheck("All folders", folder == nil) }
                Divider()
                ForEach(topFolders, id: \.self) { f in
                    Button { folder = f } label: { filterCheck(f, folder?.lowercased() == f.lowercased()) }
                }
            } label: { chip(folder ?? "All folders", system: "folder") }

            Menu {
                ForEach(Period.allCases) { p in
                    Button { period = p } label: { filterCheck(p.rawValue, period == p) }
                }
            } label: { chip(period.rawValue, system: "calendar") }

            Spacer(minLength: 0)
            Text("\(pins.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func chip(_ text: String, system: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: system).font(.caption)
            Text(text).font(.subheadline.weight(.medium)).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private func filterCheck(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary)
            Text("No places to map yet").font(.headline)
            Text("Add a location to a note (with the map pin), or adjust the filters above. Places you've already typed are being looked up in the background.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 32)
    }

    // MARK: - Geocode backfill

    /// Give coordinates to places that only have a name (older notes, typed places), so
    /// they appear on the map. Bounded and throttled to stay within the geocoder's limits;
    /// the map fills in live as results arrive (the model is observed).
    private func backfillGeocoding() async {
        guard !geocodedOnce else { return }
        geocodedOnce = true
        let targets: [(UUID, String)] = model.notes.flatMap { n in
            n.allPlaces.filter { !$0.hasCoordinate }.map { (n.id, $0.name) }
        }
        var done = 0
        for (id, name) in targets {
            guard done < 30 else { break }        // cap per open — stays well under geocoder limits
            if let c = await LocationService.coordinate(for: name) {
                model.addPlace(id, name: name, latitude: c.latitude, longitude: c.longitude)
            }
            done += 1
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
