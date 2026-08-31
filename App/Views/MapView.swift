import SwiftUI
import MapKit
import UIKit
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
    // Open centered on where you are (falls back to framing all pins if location is off).
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var openNote: NoteRef?
    @State private var selection: String?             // tapped marker's stable id
    @State private var geocodedOnce = false
    @State private var searchText = ""
    @State private var searchResult: CLLocationCoordinate2D?
    @State private var searchResultName: String?      // the resolved place/business name
    @State private var searching = false
    @State private var searchFailed = false
    @State private var locating = false
    @State private var locationDenied = false
    @State private var visibleRegion: MKCoordinateRegion?

    private struct NoteRef: Identifiable { let id: UUID }

    private struct Pin: Identifiable {
        let id: String
        let noteID: UUID
        let title: String
        let coordinate: CLLocationCoordinate2D
        let color: Color
    }

    /// Places matching the folder/time filters (from the cached `mappablePlaces`).
    private var matchingPlaces: [AppModel.MappablePlace] {
        model.mappablePlaces.filter { folderMatches($0.folderName) && period.contains($0.date) }
    }

    /// The markers to actually draw: culled to what's on-screen (plus a margin) and hard-
    /// capped, so the Map never renders thousands of markers at once. Rendering the whole set
    /// made panning glitchy and made Apple's Map drop overlapping labels (the missing company
    /// names). Off-screen pins reappear as you move; a very dense view subsamples evenly.
    private func pins(from places: [AppModel.MappablePlace]) -> [Pin] {
        var visible = places
        if let r = visibleRegion {
            let latPad = r.span.latitudeDelta * 0.65 + 0.001
            let lonPad = r.span.longitudeDelta * 0.65 + 0.001
            visible = places.filter {
                abs($0.latitude - r.center.latitude) <= latPad && abs($0.longitude - r.center.longitude) <= lonPad
            }
        }
        if visible.count > Self.markerCap {
            let step = Double(visible.count) / Double(Self.markerCap)
            visible = (0..<Self.markerCap).map { visible[Int(Double($0) * step)] }
        }
        return visible.map { mp in
            // `mp.label` is resolved once in the model (AppModel.mapLabel) — a person/venue
            // name, not raw geography — so a "Switzerland" hub linked only by Neal reads "Neal".
            Pin(id: mp.id, noteID: mp.noteID,
                title: mp.label,
                coordinate: CLLocationCoordinate2D(latitude: mp.latitude, longitude: mp.longitude),
                color: model.axis(id: mp.axisID)?.color ?? .red)
        }
    }

    private static let markerCap = 200

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
        let matching = matchingPlaces
        let currentPins = pins(from: matching)
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
            .onMapCameraChange(frequency: .onEnd) { ctx in visibleRegion = ctx.region }
            .onChange(of: selection) { _, id in
                guard let id, let mp = model.mappablePlaces.first(where: { $0.id == id }) else { return }
                openNote = NoteRef(id: mp.noteID)
                selection = nil
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    searchBar
                    if searchResult != nil { saveSearchedBar }
                    filterBar(count: matching.count)
                    reachBar(model.travelSummary(for: matching, isInPeriod: period.contains))
                }
            }
            .overlay(alignment: .bottomLeading) { locateButton.padding(.leading, 14).padding(.bottom, 30) }
            .overlay { if matching.isEmpty && searchResult == nil { emptyState } }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $openNote) { ref in
                NavigationStack { NoteDetailView(noteID: ref.id) }
            }
            .task {
                _ = await locator.currentCoordinate()   // prompt for permission so the dot/button work
                await backfillGeocoding()
            }
            // Drop the culling window as well as reframing. Pins are culled to `visibleRegion`
            // BEFORE `.automatic` gets to frame them, so filtering to a folder whose places sit
            // outside the current view left almost nothing on screen — and the camera then
            // settled on that handful, which culled to the same few again. Clearing the window
            // lets every matching place be a candidate, so `.automatic` frames the whole set.
            .onChange(of: folder) { visibleRegion = nil; position = .automatic }
            .onChange(of: period) { visibleRegion = nil; position = .automatic }
            .alert("Couldn’t find that place", isPresented: $searchFailed) {
                Button("OK", role: .cancel) {}
            } message: { Text("No location matched “\(searchText)”. Try a city, address, or landmark.") }
            .alert("Location is off", isPresented: $locationDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Enable Location for Numinous in Settings to center the map on where you are.") }
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

    // MARK: - Locate me

    /// A prominent "center on where I am" button (bottom-leading, clear of the top filter
    /// bars and the floating companion at bottom-trailing). Complements Apple's small
    /// MapUserLocationButton, which the overlay bars can hide.
    private var locateButton: some View {
        Button {
            Task { await centerOnUser() }
        } label: {
            Image(systemName: locating ? "location.fill" : "location")
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.secondary.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Center on my location")
    }

    /// Ask for location (prompting once if needed), then fly the map to where you are.
    private func centerOnUser() async {
        locating = true
        defer { locating = false }
        guard let c = await locator.currentCoordinate() else {
            if !locator.isAuthorized { locationDenied = true }
            return
        }
        withAnimation(.easeInOut(duration: 0.4)) {
            position = .region(MKCoordinateRegion(center: c,
                                                  span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)))
        }
    }

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

    // MARK: - Reach bar

    /// How much ground the pins on screen actually cover — the map's own summary of your
    /// reach, above the pins themselves. A region is a patch of world within
    /// `newGroundRadiusKm`, so this counts places you'd call different, not addresses.
    @ViewBuilder
    private func reachBar(_ summary: AppModel.TravelSummary) -> some View {
        if !summary.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "globe.americas").font(.caption2)
                Text(summary.regions == 1 ? "1 region" : "\(summary.regions) regions")
                    .fontWeight(.medium)
                if summary.newRegions > 0, let phrase = newRegionsPhrase {
                    Text("· \(summary.newRegions) new \(phrase)").foregroundStyle(.tint)
                }
                if let name = summary.farthestName, summary.farthestKm >= 50 {
                    Text("· furthest \(name), \(DistanceFormat.short(km: summary.farthestKm))")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.2)))
            .padding(.horizontal, 12)
            .accessibilityElement(children: .combine)
        }
    }

    /// What "new" means under the period filter on screen. Nothing over all time — every
    /// region is new the first time you record it, so the count would just repeat the total.
    private var newRegionsPhrase: String? {
        switch period {
        case .all:    return nil
        case .year:   return "this year"
        case .month:  return "this month"
        case .days30: return "in 30 days"
        }
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
    /// Names the geocoder has already failed on. Without this, every launch spent its whole
    /// budget retrying the same unresolvable names in the same order, so notes further down
    /// the list never got a turn — which is why whole folders stayed missing from the map.
    private static let failedKey = "geocode_failed_names"

    private func backfillGeocoding() async {
        guard !geocodedOnce else { return }
        geocodedOnce = true

        var failed = Set(UserDefaults.standard.stringArray(forKey: Self.failedKey) ?? [])

        // One lookup per DISTINCT name, not per note. The same place on forty notes used to
        // cost forty geocodes out of a budget of thirty.
        var byName: [String: [UUID]] = [:]
        for n in model.notes {
            for p in n.allPlaces where !p.hasCoordinate {
                let key = p.name.trimmingCharacters(in: .whitespaces)
                // Only geocode names that could BE a place. Without this the backfill happily
                // resolved things like a person's name to whatever the geocoder matched, and
                // that coordinate then showed up as a pin somewhere it had no business being.
                guard !key.isEmpty, LocationService.looksLikePlace(key),
                      !failed.contains(key.lowercased()) else { continue }
                byName[key, default: []].append(n.id)
            }
        }
        guard !byName.isEmpty else { return }

        var batch: [(id: UUID, name: String, latitude: Double, longitude: Double)] = []
        var done = 0
        func flush() {
            guard !batch.isEmpty else { return }
            model.addPlaces(batch)          // save progress as we go
            batch.removeAll(keepingCapacity: true)
        }

        for (name, ids) in byName {
            if Task.isCancelled { break }   // left the tab — keep whatever we resolved
            guard done < 60 else { break }
            if let c = await LocationService.coordinate(for: name) {
                for id in ids { batch.append((id, name, c.latitude, c.longitude)) }
            } else {
                failed.insert(name.lowercased())   // don't burn next launch's budget on it again
            }
            done += 1
            if batch.count >= 8 { flush() }
            try? await Task.sleep(nanoseconds: 1_200_000_000)   // ~50/min, the geocoder's limit
        }
        flush()
        UserDefaults.standard.set(Array(failed), forKey: Self.failedKey)
    }
}
