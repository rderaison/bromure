import SwiftUI

/// First-time consent popup shown before enabling AI-based phishing
/// detection. Mirrors the Cloudflare WARP EULA flow — user must explicitly
/// opt in because the feature sends page signals to a remote server.
struct PhishingConsentView: View {
    let serverHost: String
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "shield.righthalf.filled")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("AI Phishing Detection")
                    .font(.title2.bold())
                Text("Bromure can analyze pages with a large language model to flag scams and phishing attempts before you fall for them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    bullet(
                        icon: "paperplane.fill",
                        title: "What gets sent",
                        text: "When a page looks suspicious, Bromure sends the URL, the page\u{2019}s visible text, form structure, and detected warning signals (e.g. look-alike domains, credential prompts) to the analysis server."
                    )
                    bullet(
                        icon: "network",
                        title: "Where it goes",
                        text: "Requests go to \(serverHost), operated by Bromure. This is a third-party server from the browser\u{2019}s perspective — data leaves the local VM."
                    )
                    bullet(
                        icon: "clock.arrow.circlepath",
                        title: "Retention",
                        text: "Analysis requests may be logged for abuse prevention and model improvement. Don\u{2019}t enable this on profiles that browse highly sensitive content."
                    )
                    bullet(
                        icon: "hand.raised.fill",
                        title: "Your choice",
                        text: "You can turn this off at any time in Profile Settings \u{2192} Privacy & Safety. It is disabled by default on every new profile."
                    )
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
            .background(.background.secondary)

            Divider()

            VStack(spacing: 12) {
                Text("By clicking Accept, you agree to have the pages you browse in this profile analyzed by the Bromure phishing-detection service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    Button("Decline") { onDecline() }
                        .keyboardShortcut(.cancelAction)

                    Button("Accept") { onAccept() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 16)
        }
        .frame(width: 520)
    }

    private func bullet(icon: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
