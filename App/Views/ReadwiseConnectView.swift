import SwiftUI

/// Connect a Readwise account (paste the access token) and sync Kindle + other
/// highlights into the library. The token is entered by you — Numinous never
/// asks for your Amazon or Readwise password.
struct ReadwiseConnectView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var tokenField = ""
    @State private var phase: Phase = .idle

    enum Phase: Equatable { case idle, syncing, done(String), error(String) }

    var body: some View {
        NavigationStack {
            Form {
                if model.isReadwiseConnected {
                    connectedSection
                } else {
                    connectSection
                }

                switch phase {
                case .syncing:
                    HStack(spacing: 10) { ProgressView(); Text("Syncing your highlights…") }
                case .done(let message):
                    Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .error(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .idle:
                    EmptyView()
                }
            }
            .navigationTitle("Readwise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var connectSection: some View {
        Section {
            TextField("Readwise access token", text: $tokenField)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())
            Button {
                openURL(URL(string: "https://readwise.io/access_token")!)
            } label: {
                Label("Get your token", systemImage: "safari")
            }
            Button {
                model.setReadwiseToken(tokenField)
                Task { await sync() }
            } label: {
                Text("Connect & sync")
            }
            .disabled(tokenField.trimmingCharacters(in: .whitespaces).isEmpty || phase == .syncing)
        } header: {
            Text("Connect")
        } footer: {
            Text("Readwise syncs your Kindle highlights (and articles, podcasts). Paste the token from readwise.io/access_token. Highlights become notes that grow Mind — and any [[link]] in a highlight joins your web. Nothing leaves your device except the request to Readwise.")
        }
    }

    private var connectedSection: some View {
        Section {
            Label("Connected to Readwise", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            Button {
                Task { await sync() }
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(phase == .syncing)
            Button(role: .destructive) {
                model.setReadwiseToken(nil)
                phase = .idle
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        } footer: {
            Text("Re-syncing updates books you've already imported (matched by Readwise id) instead of duplicating them, and pulls in new highlights.")
        }
    }

    private func sync() async {
        guard let token = model.readwiseToken else { return }
        phase = .syncing
        do {
            let books = try await ReadwiseService.fetch(token: token)
            let (added, updated) = model.importReadwise(books)
            phase = .done("Synced \(books.count) books — \(added) new, \(updated) updated.")
        } catch let error as ReadwiseService.ReadwiseError {
            if case .badToken = error { model.setReadwiseToken(nil) }
            phase = .error(error.localizedDescription)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
