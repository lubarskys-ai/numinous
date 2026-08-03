import Foundation
import Contacts

/// A contact read from the device — its stable identifier plus the bits worth
/// keeping as note details. On-device only; nothing is uploaded.
struct ImportedContact {
    let id: String
    let name: String
    let phones: [String]
    let emails: [String]
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
            out.append(ImportedContact(id: contact.identifier, name: name, phones: phones, emails: emails))
        }
        return out
    }
}
