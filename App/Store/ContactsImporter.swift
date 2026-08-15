import Foundation
import Contacts

/// A contact read from the device — its stable identifier plus the bits worth
/// keeping as note details. On-device only; nothing is uploaded.
struct ImportedContact {
    let id: String
    let name: String
    let phones: [String]
    let emails: [String]
    /// A readable "City, State" from the contact's postal address, if any — the seed for
    /// location-based reconnection ("you're near Sam").
    let place: String?
    /// Concierge dollar tiers found in the contact's fields (e.g. ["$5000"]) — each becomes
    /// a `[[concierge/$X]]` link, grouping contacts by tier.
    let conciergeTiers: [String]
}

/// Reads the device's contacts (with permission). Seeds the People folder so
/// linking a person is a tap, not typing — and re-imports update, not duplicate.
enum ContactsImporter {

    enum ImportError: Error { case accessDenied }

    /// True only when access is already granted — so we can auto-sync on launch
    /// without ever triggering the permission prompt.
    static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    static func fetchContacts() async throws -> [ImportedContact] {
        let store = CNContactStore()

        let granted: Bool = try await withCheckedThrowingContinuation { cont in
            store.requestAccess(for: .contacts) { ok, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ok) }
            }
        }
        guard granted else { throw ImportError.accessDenied }

        let keys = [
            CNContactGivenNameKey, CNContactFamilyNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            CNContactPostalAddressesKey,
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)

        var out: [ImportedContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            let emails = contact.emailAddresses.map { $0.value as String }
            let place = contact.postalAddresses.first.map { pa -> String in
                let a = pa.value
                return [a.city, a.state].filter { !$0.isEmpty }.joined(separator: ", ")
            }.flatMap { $0.isEmpty ? nil : $0 }
            // Scan the WHOLE address (street, city, state, etc.) plus the name for concierge
            // dollar tiers — the amount often sits in a street/address line, not city/state.
            let addressText = contact.postalAddresses.map { pa -> String in
                let a = pa.value
                return [a.street, a.subLocality, a.city, a.subAdministrativeArea, a.state, a.postalCode, a.country]
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }.joined(separator: " · ")
            let tiers = conciergeTiers(in: name + " " + addressText)
            out.append(ImportedContact(id: contact.identifier, name: name, phones: phones, emails: emails,
                                       place: place, conciergeTiers: tiers))
        }
        return out
    }

    /// The concierge dollar tiers present in `text` — matches $2000 / $3,000 / $4000 / $5000
    /// (the `$` is required so street numbers like "2000 Main St" aren't mistaken for a tier).
    static func conciergeTiers(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\$\s?([2345]),?000(?![0-9])"#) else { return [] }
        let ns = text as NSString
        var tiers = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            tiers.insert("$\(ns.substring(with: m.range(at: 1)))000")
        }
        return tiers.sorted()
    }
}
