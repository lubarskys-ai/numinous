import Foundation
import CoreLocation

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
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
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
        if let poi = p.areasOfInterest?.first, !poi.isEmpty { return poi }
        let parts = [p.locality ?? p.subAdministrativeArea, p.administrativeArea].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
