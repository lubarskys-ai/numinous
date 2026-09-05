import Foundation
import CoreLocation
import MapKit
import NuminousCore

/// One-shot current-place lookup: asks for when-in-use permission, grabs a single
/// location fix, and reverse-geocodes it to a readable place — a nearby point of
/// interest when there is one, else "City, State". All on-device via Apple's
/// geocoder; nothing leaves the phone except the request to Apple's maps service.
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<Bool, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // Best fix so a captured place is precise (street/venue level) rather than a
        // ~100m blob that can land on the wrong building or blur which town you're in.
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Already granted, so we can auto-fill without prompting.
    var isAuthorized: Bool {
        let s = manager.authorizationStatus
        return s == .authorizedWhenInUse || s == .authorizedAlways
    }

    /// The current place name, or nil if unavailable / denied.
    func currentPlace() async -> String? {
        guard await ensureAuthorized(), let location = await requestLocation() else { return nil }
        return await Self.placeName(for: location)
    }

    /// The current "City, State" specifically (never a point-of-interest name) — the
    /// reliable form for location matching / reconnection.
    func currentRegion() async -> String? {
        guard await ensureAuthorized(), let location = await requestLocation() else { return nil }
        let geocoder = CLGeocoder()
        guard let p = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
        let parts = [p.locality ?? p.subAdministrativeArea, p.administrativeArea].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The current place as a structured `Place` — name plus exact coordinates, so a
    /// GPS-captured location is map-ready. Falls back to a "lat, long" name if the
    /// reverse-geocode has no readable name.
    func currentPlaceStructured() async -> Place? {
        guard await ensureAuthorized(), let location = await requestLocation() else { return nil }
        let c = location.coordinate
        let name = await Self.placeName(for: location)
            ?? String(format: "%.4f, %.4f", c.latitude, c.longitude)
        return Place(name: name, latitude: c.latitude, longitude: c.longitude)
    }

    /// Forward-geocode a place name to coordinates. `near` biases the search to a region
    /// (so a chain like "Dunkin" resolves to the branch nearest you). Nil if it doesn't
    /// look like a place, can't be resolved, or resolves only to a vague fallback — so a
    /// reminder like "Christina Ewoldt $5000" never becomes a pin.
    static func coordinate(for name: String, near center: CLLocationCoordinate2D? = nil) async -> (latitude: Double, longitude: Double)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard looksLikePlace(trimmed) else { return nil }
        let geocoder = CLGeocoder()
        let region = center.map { CLCircularRegion(center: $0, radius: 60_000, identifier: "bias") }
        guard let mark = try? await geocoder.geocodeAddressString(trimmed, in: region, preferredLocale: nil).first,
              let loc = mark.location else { return nil }
        // Require it to have resolved to a REAL named place (a city/region/country/POI),
        // not a lenient guess — CLGeocoder happily returns a centroid for junk otherwise.
        let resolved = mark.locality ?? mark.administrativeArea ?? mark.country ?? mark.areasOfInterest?.first
        guard resolved != nil else { return nil }
        return (loc.coordinate.latitude, loc.coordinate.longitude)
    }

    /// The coordinate of a name ONLY when it names a REGION — a city, state/province, or
    /// country — not a specific street or venue. Used to infer roughly where a note is "about"
    /// (a trip's country/city), so its other place links resolve there instead of near you.
    static func regionCenter(for name: String) async -> CLLocationCoordinate2D? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard looksLikePlace(trimmed) else { return nil }
        let geocoder = CLGeocoder()
        guard let m = try? await geocoder.geocodeAddressString(trimmed).first, let loc = m.location else { return nil }
        // Accept a locality / admin area / country, but not a street address (a specific spot).
        let namesRegion = (m.locality != nil || m.administrativeArea != nil || m.country != nil)
        return (namesRegion && m.thoroughfare == nil) ? loc.coordinate : nil
    }

    /// Find a business / point of interest by name via MKLocalSearch — which understands
    /// restaurants, cafés, shops, landmarks, the things the plain address geocoder misses.
    /// Biased toward `near` when given. Returns the resolved name + coordinate, or nil.
    static func searchPlace(_ name: String, near center: CLLocationCoordinate2D? = nil,
                            radiusMeters: CLLocationDistance = 60_000) async -> (name: String, latitude: Double, longitude: Double)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard looksLikePlace(trimmed) else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: radiusMeters, longitudinalMeters: radiusMeters)
        }
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let c = item.placemark.coordinate
        return (item.name ?? trimmed, c.latitude, c.longitude)
    }

    /// Several matching places for a query (name or address), so the UI can show a list to
    /// pick from when a name is ambiguous (many "Starbucks"). Biased toward `near`.
    static func searchPlaces(_ query: String, near center: CLLocationCoordinate2D? = nil, limit: Int = 15)
        async -> [(name: String, subtitle: String, latitude: Double, longitude: Double)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return [] }
        return items.prefix(limit).map { item in
            let c = item.placemark.coordinate
            return (item.name ?? trimmed, addressLine(item.placemark), c.latitude, c.longitude)
        }
    }

    /// WHICH VENUE YOU ARE ACTUALLY IN, or nil when the honest answer is "a street address".
    ///
    /// The Action Button used to take the nearest point of interest within 150 metres and log
    /// it, whatever it was and however far away. Standing at home that logs the petrol station
    /// down the road; standing in a strip mall it logs whichever unit is nearest the centroid
    /// of a GPS guess. It was confidently wrong, which is the worst way for it to be wrong,
    /// because a diary entry saying you were somewhere you have never been is harder to
    /// notice than a missing one.
    ///
    /// Two rules, both derived from the fix rather than guessed at:
    ///
    ///   SEARCH NO WIDER THAN YOU CAN SEE. The radius follows the fix's own accuracy, so a
    ///   vague fix does not get a wider net to pull a wrong answer out of — it gets a
    ///   narrower one and usually returns nothing.
    ///   ACCEPT ONLY WHAT IS CLOSER THAN THE ERROR. A venue further away than the fix's own
    ///   margin of error cannot be distinguished from its neighbours, so it is not claimed.
    ///
    /// When neither holds, the caller falls back to the address — which is vaguer and true.
    static func venueHere(_ fix: CLLocation) async -> (name: String, latitude: Double, longitude: Double, metres: Double)? {
        let accuracy = fix.horizontalAccuracy > 0 ? fix.horizontalAccuracy : 100
        guard accuracy <= 120 else { return nil }        // too vague to name a building
        let radius = min(max(accuracy, 25), 120)
        let request = MKLocalPointsOfInterestRequest(center: fix.coordinate, radius: radius)
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return nil }

        let scored = items.compactMap { item -> (String, Double, Double, Double)? in
            guard let name = item.name else { return nil }
            let c = item.placemark.coordinate
            let d = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: fix)
            return (name, c.latitude, c.longitude, d)
        }.sorted { $0.3 < $1.3 }

        guard let best = scored.first, best.3 <= max(30, accuracy) else { return nil }
        // Two venues equally close is a strip mall, and picking one is a coin toss dressed
        // up as a fact.
        if scored.count > 1, scored[1].3 - best.3 < 12, accuracy > 20 { return nil }
        return (best.0, best.1, best.2, best.3)
    }

    /// Businesses / points of interest within ~`radius` metres of a coordinate, NEAREST FIRST —
    /// so "find my location" can offer the real venues around you (a café, a shop, a park)
    /// instead of only a street address. Each result carries a "N m away" subtitle.
    static func nearbyPlaces(_ center: CLLocationCoordinate2D, radius: CLLocationDistance = 150, limit: Int = 12)
        async -> [(name: String, subtitle: String, latitude: Double, longitude: Double)] {
        let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return [] }
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return items
            .compactMap { item -> (name: String, lat: Double, lng: Double, dist: Double)? in
                guard let name = item.name else { return nil }
                let c = item.placemark.coordinate
                let d = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here)
                return (name, c.latitude, c.longitude, d)
            }
            .sorted { $0.dist < $1.dist }
            .prefix(limit)
            .map { (name: $0.name, subtitle: distanceLabel($0.dist), latitude: $0.lat, longitude: $0.lng) }
    }

    private static func distanceLabel(_ metres: Double) -> String {
        metres < 1000 ? "\(Int(metres.rounded())) m away" : String(format: "%.1f km away", metres / 1000)
    }

    /// A short address line for a search result — "123 Main St, San Francisco, CA".
    private static func addressLine(_ p: CLPlacemark) -> String {
        [p.thoroughfare, p.locality ?? p.subAdministrativeArea, p.administrativeArea]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Just the current coordinate (no reverse-geocode to a name) — used to bias a name
    /// lookup to where you are.
    func currentCoordinate() async -> CLLocationCoordinate2D? {
        await currentFix()?.coordinate
    }

    /// The whole fix, ACCURACY INCLUDED, because the accuracy is the part that matters when
    /// deciding which venue you are standing in.
    ///
    /// currentCoordinate() threw the CLLocation away and returned only the coordinate, which
    /// meant the Action Button treated a 165-metre cold GPS fix exactly like a 5-metre one and
    /// then confidently named whichever business happened to be nearest that guess.
    ///
    /// A first fix indoors is often poor and improves within a couple of seconds, so one
    /// retry is worth the wait when the first is bad.
    func currentFix(acceptableAccuracy: CLLocationDistance = 65) async -> CLLocation? {
        guard await ensureAuthorized(), let first = await requestLocation() else { return nil }
        if first.horizontalAccuracy <= acceptableAccuracy && first.horizontalAccuracy > 0 {
            return first
        }
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        guard let second = await requestLocation() else { return first }
        // Whichever is better; a negative accuracy means "invalid", so it never wins.
        let firstOK = first.horizontalAccuracy > 0 ? first.horizontalAccuracy : .greatestFiniteMagnitude
        let secondOK = second.horizontalAccuracy > 0 ? second.horizontalAccuracy : .greatestFiniteMagnitude
        return secondOK < firstOK ? second : first
    }

    /// A cheap sanity check that a string is plausibly a place/address — not a dollar
    /// amount, phone number, id, or a reminder someone stashed in a contact field. Keeps
    /// non-location junk from being geocoded into (or shown as) a map pin.
    static func looksLikePlace(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 3 else { return false }
        if s.contains(where: { "$€£¥₹@".contains($0) }) { return false }   // amounts / emails, not places (# is ok — apt numbers)
        let letters = s.filter { $0.isLetter }.count
        let digits = s.filter { $0.isNumber }.count
        guard letters >= 3 else { return false }        // a place has real words
        if digits > letters { return false }            // mostly-numeric → not a place
        return true
    }

    private func ensureAuthorized() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                authContinuation = cont
                manager.requestWhenInUseAuthorization()
            }
        default: return false
        }
    }

    private func requestLocation() async -> CLLocation? {
        await withCheckedContinuation { cont in
            locationContinuation = cont
            manager.requestLocation()
            // Safety net: if no fix (or error) arrives, don't hang the caller forever.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let c = locationContinuation { locationContinuation = nil; c.resume(returning: nil) }
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let cont = authContinuation, manager.authorizationStatus != .notDetermined else { return }
        authContinuation = nil
        cont.resume(returning: isAuthorized)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locationContinuation?.resume(returning: locations.last)
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(returning: nil)
        locationContinuation = nil
    }

    // MARK: Reverse geocode

    private static func placeName(for location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        guard let p = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
        let city = p.locality ?? p.subLocality ?? p.subAdministrativeArea

        // Most specific first: a street address ("1200 Getty Center Dr, Los Angeles").
        if let street = p.thoroughfare {
            let line = [p.subThoroughfare, street].compactMap { $0 }.joined(separator: " ")
            return [line, city].compactMap { $0 }.joined(separator: ", ")
        }
        // Then a named venue/POI — but NOT a giant area-of-interest like a national forest,
        // which otherwise mislabels a whole region (the "Tahoe National Forest" bug).
        if let name = p.name, name != city, name != p.administrativeArea,
           !(p.areasOfInterest?.contains(name) ?? false) {
            return [name, city].compactMap { $0 }.joined(separator: ", ")
        }
        // Then the town/city.
        if let city {
            return [city, p.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        }
        // Only out in the wild (no street, no town) do we fall back to the park name.
        if let poi = p.areasOfInterest?.first, !poi.isEmpty { return poi }
        return p.administrativeArea
    }
}
