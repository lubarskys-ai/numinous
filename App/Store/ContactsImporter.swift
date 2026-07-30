import Foundation
import Contacts

/// Reads the device's contacts (with permission) and returns their display
/// names. On-device only — nothing is uploaded; this just seeds the People
/// folder so linking a person is a tap, not typing.
enum ContactsImporter {

    enum ImportError: Error { case accessDenied }

    /// Requests Contacts access and returns contact display names.
    static func fetchNames() async throws -> [String] {
        let store = CNContactStore()

        let granted: Bool = try await withCheckedThrowingContinuation { cont in
            store.requestAccess(for: .contacts) { ok, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ok) }
            }
        }
        guard granted else { throw ImportError.accessDenied }

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)

        var names: [String] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.append(name) }
        }
        return names
    }
}
