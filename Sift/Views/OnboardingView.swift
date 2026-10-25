import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("Sift").font(.largeTitle.bold())
                    Text("A calmer front end for Fastmail. New senders wait in the Screener until you say yes; spy pixels are stripped; nothing buzzes unless you ask it to.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Connect your Fastmail account").font(.headline)
                    Text("In Fastmail's **Settings → Privacy & Security**, create an **API token** (not an app password) with **Email**, **Email submission**, and **Contacts** access. Sift keeps it in your iCloud Keychain.")
                        .font(.callout)
                    Link("How to create a Fastmail API token", destination: URL(string: "https://www.fastmail.help/hc/en-us/articles/5254602856719")!)
                        .font(.callout)
                    SecureField("API token (fmu1-…)", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit(connect)
                    if let hint = formatHint {
                        Label(hint, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(action: connect) {
                        Group {
                            if isConnecting {
                                ProgressView()
                            } else {
                                Text("Connect")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(cleanedToken.isEmpty || isConnecting)
                }

                if case .failed(let message) = model.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("What Sift changes in Fastmail").font(.headline)
                    Label("Adds “Screener” and “Screened Out” mailboxes.", systemImage: "tray.2")
                    Label("Keeps your screening decisions in a few “Sift: …” contact groups. No contact is created for each sender.", systemImage: "person.crop.rectangle.stack")
                    Label("Only mail that arrives after you connect is screened. Older mail stays where it is.", systemImage: "clock.arrow.circlepath")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Button("Explore with sample mail") {
                    Task { await model.startDemo() }
                }
                .buttonStyle(.bordered)
            }
            .padding(28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private var isConnecting: Bool { model.phase == .connecting }

    /// Pasted tokens sometimes carry line breaks, spaces, or a "Bearer " prefix.
    private var cleanedToken: String {
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") { value = String(value.dropFirst(7)) }
        return value.filter { !$0.isWhitespace }
    }

    private var formatHint: String? {
        let value = cleanedToken
        guard !value.isEmpty, !value.lowercased().hasPrefix("fmu") else { return nil }
        return "Fastmail API tokens start with “fmu1-”. An app password (for IMAP, SMTP or CalDAV) won't work here."
    }

    private func connect() {
        let value = cleanedToken
        guard !value.isEmpty, !isConnecting else { return }
        Task { await model.connect(token: value) }
    }
}
