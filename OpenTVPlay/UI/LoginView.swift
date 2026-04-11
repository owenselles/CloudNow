import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct LoginView: View {
    @Environment(AuthManager.self) var authManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch authManager.loginPhase {
            case .idle:
                loginPrompt
            case .showingPIN(let code, let url, let urlComplete):
                pinView(code: code, url: url, urlComplete: urlComplete)
            case .exchangingTokens:
                exchangingView
            case .failed(let message):
                failedView(message: message)
            }
        }
    }

    // MARK: Login Prompt

    private var loginPrompt: some View {
        VStack(spacing: 48) {
            VStack(spacing: 12) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white)
                Text("OpenTVPlay")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("GeForce NOW for Apple TV")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Button {
                authManager.login()
            } label: {
                Label("Sign in with NVIDIA", systemImage: "person.badge.key")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.bordered)
            .tint(.green)
        }
        .padding(80)
    }

    // MARK: PIN Display

    private func pinView(code: String, url: String, urlComplete: String) -> some View {
        VStack(spacing: 40) {
            Text("Sign in to GeForce NOW")
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)

            // QR code
            if let qrImage = generateQRCode(from: urlComplete) {
                qrImage
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .cornerRadius(16)
            }

            // Instructions
            VStack(spacing: 12) {
                Text("Scan the QR code, or go to:")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(url)
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("and enter this PIN:")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // PIN display
            let formattedPIN = formatPIN(code)
            Text(formattedPIN)
                .font(.system(size: 72, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)
                .tracking(8)

            // Waiting indicator
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.secondary)
                Text("Waiting for sign in...")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel") {
                authManager.cancelLogin()
            }
            .buttonStyle(.bordered)
            .tint(.gray)
        }
        .padding(60)
    }

    // MARK: Exchanging Tokens

    private var exchangingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(2)
                .tint(.white)
            Text("Signing in...")
                .font(.title2)
                .foregroundStyle(.white)
        }
    }

    // MARK: Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 32) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.yellow)
            Text("Sign In Failed")
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 24) {
                Button("Try Again") {
                    authManager.login()
                }
                .buttonStyle(.bordered)
                .tint(.green)

                Button("Cancel") {
                    authManager.cancelLogin()
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            }
        }
        .padding(80)
    }

    // MARK: Helpers

    private func formatPIN(_ code: String) -> String {
        guard code.count == 8 else { return code }
        let left = code.prefix(4)
        let right = code.suffix(4)
        return "\(left) \u{2014} \(right)"
    }

    private func generateQRCode(from string: String) -> Image? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
