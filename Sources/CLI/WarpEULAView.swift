import SwiftUI

struct WarpEULAView: View {
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                Text("Cloudflare WARP")
                    .font(.title2.bold())
                Text("Bromure can route your VM traffic through Cloudflare\u{2019}s encrypted WARP network for additional privacy and security.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                Text(Self.eulaText)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .background(.background.secondary)

            Divider()

            VStack(spacing: 12) {
                Text("By clicking Accept, you agree to the Cloudflare Application Terms of Service and Privacy Policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    Button("Decline") {
                        onDecline()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Accept") {
                        onAccept()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 16)
        }
        .frame(width: 500)
    }

    static let eulaText = """
    CLOUDFLARE APPLICATION TERMS OF SERVICE
    https://www.cloudflare.com/application/terms/

    SCOPE OF LICENSE
    You are granted a non-exclusive, personal, revocable, non-transferable \
    license to use the Application on the device for which it is provided \
    and that you own or control. You agree not to modify, decompile, \
    reverse engineer, or create derivative works of the Application.

    VPN PROFILE
    The Application is not designed to hide your identity from the \
    Internet properties you access. Cloudflare will assign you a \
    virtual IP address to connect to the Cloudflare network but this \
    virtual IP address does not mask your identity.

    USER RESPONSIBILITIES
    You must not use the Application for any illegal activities or to \
    interfere with, disrupt, alter, or modify the Application or any \
    part of it.

    PRIVACY
    Please review Cloudflare's privacy policy at:
    https://www.cloudflare.com/application/privacypolicy/

    Cloudflare may collect anonymized performance and diagnostic data \
    to improve the service. DNS queries processed through the \
    Application are subject to Cloudflare's resolver commitments.

    WARRANTY DISCLAIMER
    The Application is provided "AS IS" and "AS AVAILABLE" without \
    warranty of any kind, express or implied.

    DISPUTE RESOLUTION
    Any disputes shall be resolved through binding arbitration in \
    San Francisco County, California. You agree to waive class action \
    participation rights.

    Full terms: https://www.cloudflare.com/application/terms/
    Privacy policy: https://www.cloudflare.com/application/privacypolicy/
    """
}
