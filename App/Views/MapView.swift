import SwiftUI
import MapKit
import NuminousCore

/// A map of where your life happened: every note place that has coordinates, plotted
/// and colored by its axis. Tap a pin to open the note. Search a place by name to jump
/// there, or tap the location button to center on where you are now. Filters narrow the
/// dataset by folder and time period.
struct MapView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var locator = LocationService()

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
    @State private var selection: String?             // tapped marker's stable id
    @State private var geocodedOnce = false
    @State private var searchText = ""
    @State private var searchResult: CLLocationCoordinate2D?
    @State private var searchResultName: String?      // the resolved place/business name
    @State private var searching = false
    @State private var searchFailed = false

    private struct NoteRef: Identifiable { let id: UUID }

    private struct Pin: Identifiable {
        let id: String
        let noteID: UUID
        let title: String
        let coordinate: CLLocationCoordinate2D
        let color: Color
    }

    /// Plottable places matching the current filters — built from the model's cached
    /// `mappablePlaces`, so this no longer rescans every note on every render.
    private var pins: [Pin] {
        model.mappablePlaces.compactMap { mp in
            guard folderMatches(mp.folderName), period.contains(mp.date) else { return nil }
            // Label the pin with the LOCATION name, not the note's title (which for a diary
            // entry is just its date).
            return Pin(id: mp.id, noteID: mp.noteID, title: mp.placeName,
                       coordinate: CLLocationCoordinate2D(latitude: mp.latitude, longitude: mp.longitude),
                       color: model.axis(id: mp.axisID)?.color ?? .red)
        }
    }

    private func folderMatches(_ folderName: String) -> Bool {
        guard let folder else { return true }
        let f = folderName.lowercased(), sel = folder.lowercased()
        return f == sel || f.hasPrefix(sel + "/")
    }

    /// Distinct top-level folders that actually contain notes, for the folder filter.
    private var topFolders: [String] {
        var seen = Set<String>(); var out: [String] = []
        for mp in model.mappablePlaces {
            let top = mp.folderName.split(separator: "/").first.map(String.init) ?? ""
            if !top.isEmpty, seen.insert(top.lowercased()).inserted { out.append(top) }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        let currentPins = pins
        NavigationStack {
            Map(position: $position, selection: $selection) {
                UserAnnotation()            // the blue "you are here" dot (when authorized)
                ForEach(currentPins) { pin in
                    Marker(pin.title, systemImage: "mappin", coordinate: pin.coordinate)
                        .tint(pin.color)
                        .tag(pin.id)
                }
                if let searchResult {
                    Marker(searchResultName ?? "Search result", systemImage: "mappin", coordinate: searchResult)
                        .tint(.blue)
                }
            }
            // Show map POIs (restaurants, cafés, shops…) so you can find a place by browsing too.
            .mapStyle(.standard(pointsOfInterest: .including([
                .restaurant, .cafe, .bakery, .brewery, .winery, .nightlife,
                .hotel, .store, .park, .museum, .movieTheater, .fitnessCenter])))
            .mapControls { MapUserLocationButton(); MapCompass() }
            .onChange(of: selection) { _, id in
                guard let id, let mp = model.mappablePlaces.first(where: { $0.id == id }) else { return }
                openNote = NoteRef(id: mp.noteID)
                selection = nil
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    searchBar
                    if searchResult != nil { saveSearchedBar }
                    filterBar(count: currentPins.count)
                }
            }
            .overlay { if currentPins.isEmpty && searchResult == nil { emptyState } }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $openNote) { ref in
                NavigationStack { NoteDetailView(noteID: ref.id) }
            }
            .task {
                _ = await locator.currentCoordinate()   // prompt for permission so the dot/button work
                await backfillGeocoding()
            }
            .onChange(of: folder) { position = .automatic }
            .onChange(of: period) { position = .automatic }
            .alert("Couldn’t find that place", isPresented: $searchFailed) {
                Button("OK", role: .cancel) {}
            } message: { Text("No location matched “\(searchText)”. Try a city, address, or landmark.") }
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search a place — city, address, landmark", text: $searchText)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
            if searching { ProgressView().controlSize(.small) }
            else if !searchText.isEmpty {
                Button { searchText = ""; searchResult = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.2)))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    /// When a search has landed on a place, offer to attach it to a note — either as its
    /// own place note or onto today's diary entry.
    private var saveSearchedBar: some View {
        Menu {
            Button { saveSearchedAsNote() } label: {
                Label("Save as a place note", systemImage: "mappin.and.ellipse")
            }
            Button { addSearchedToDiary() } label: {
                Label("Add to today's diary", systemImage: "calendar.badge.plus")
            }
        } label: {
            Label("Add “\(resolvedName)” to a note", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.25)))
        }
        .padding(.horizontal, 12)
    }

    /// The name to save — the resolved business/place name when we have one, else the query.
    private var resolvedName: String {
        (searchResultName ?? searchText).trimmingCharacters(in: .whitespaces)
    }

    private func saveSearchedAsNote() {
        guard let c = searchResult else { return }
        let id = model.createPlaceNote(name: resolvedName, latitude: c.latitude, longitude: c.longitude)
        clearSearch()
        openNote = NoteRef(id: id)
    }

    private func addSearchedToDiary() {
        guard let c = searchResult else { return }
        let diaryID = model.openTodayDiary()
        model.addPlace(diaryID, name: resolvedName, latitude: c.latitude, longitude: c.longitude)
        clearSearch()
        openNote = NoteRef(id: diaryID)
    }

    private func clearSearch() { searchText = ""; searchResult = nil; searchResultName = nil }

    private func runSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        let near = await locator.currentCoordinate()

        // MKLocalSearch understands businesses/POIs (restaurants, cafés, shops), which a
        // plain geocoder does not — so "Blue Bottle" or "Tartine" actually resolves.
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let near {
            request.region = MKCoordinateRegion(center: near, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        if let item = try? await MKLocalSearch(request: request).start().mapItems.first {
            centerOnResult(item.placemark.coordinate, name: item.name ?? q, zoom: 0.04)
            return
        }
        // Fallback: a plain address/city via the geocoder.
        if let c = await LocationService.coordinate(for: q, near: near) {
            centerOnResult(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude), name: q, zoom: 0.15)
        } else {
            searchFailed = true
        }
    }

    private func centerOnResult(_ coord: CLLocationCoordinate2D, name: String, zoom: Double) {
        searchResult = coord
        searchResultName = name
        withAnimation {
            position = .region(MKCoordinateRegion(
                center: coord, span: MKCoordinateSpan(latitudeDelta: zoom, longitudeDelta: zoom)))
        }
    }

    // MARK: - Filter bar

    private func filterBar(count: Int) -> some View {
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
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 12)
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
        var results: [(id: UUID, name: String, latitude: Double, longitude: Double)] = []
        var done = 0
        for (id, name) in targets {
            guard done < 30 else { break }        // cap per open — stays well under geocoder limits
            if let c = await LocationService.coordinate(for: name) {
                results.append((id, name, c.latitude, c.longitude))
            }
            done += 1
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        // Apply all at once — one save, one map refresh, instead of 30 (which made the map
        // sticky while it geocoded in the background).
        if !results.isEmpty { model.addPlaces(results) }
    }
}
