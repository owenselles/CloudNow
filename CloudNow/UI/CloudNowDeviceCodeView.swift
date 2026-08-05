import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct CloudNowDeviceCodeView: View {
    let title: String
    let code: String
    let verificationURL: String
    let verificationURLComplete: String
    var accentColor: Color = .green
    var accessibilityIdentifier = "device-code-login"
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 40) {
            Text(title)
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityIdentifier(accessibilityIdentifier)

            QRCodeView(payload: verificationURLComplete)
                .frame(width: 280, height: 280)
                .clipShape(.rect(cornerRadius: 16))
                .accessibilityLabel(L10n.text("scan_qr_or_go_to"))
                .accessibilityValue(verificationURLComplete)
                .accessibilityIdentifier("\(accessibilityIdentifier).qr")

            VStack(spacing: 12) {
                Text(L10n.text("scan_qr_or_go_to"))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(verificationURL)
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("\(accessibilityIdentifier).verification-url")
                Text(L10n.text("and_enter_pin"))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text(formattedCode)
                .font(.system(size: 72, weight: .bold, design: .monospaced))
                .foregroundStyle(accentColor)
                .tracking(8)
                .accessibilityIdentifier("\(accessibilityIdentifier).code")

            HStack(spacing: 12) {
                ProgressView()
                    .tint(.secondary)
                Text(L10n.text("waiting_for_sign_in"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Button(L10n.text("cancel"), action: onCancel)
                .buttonStyle(.bordered)
                .tint(.gray)
                .accessibilityIdentifier("\(accessibilityIdentifier).cancel")
        }
        .padding(60)
    }

    private var formattedCode: String {
        guard code.count == 8 else { return code }
        return "\(code.prefix(4)) \u{2014} \(code.suffix(4))"
    }
}

private struct QRCodeView: View {
    let payload: String
    @State private var renderState = QRCodeRenderState<Image>()

    var body: some View {
        Group {
            if let image = renderState.value {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.white
                    .overlay {
                        ProgressView()
                            .tint(.black)
                    }
            }
        }
        .task(id: payload) {
            renderState.begin(payload: payload)
            let rendered = await QRCodeRenderer.shared.render(payload: payload)
            guard !Task.isCancelled else { return }
            let image = rendered.map {
                Image(decorative: $0.image, scale: 1)
            }
            renderState.complete(with: image, payload: payload)
        }
    }
}

struct QRCodeRenderState<Value> {
    private(set) var value: Value?
    private var activePayload: String?

    init() {}

    mutating func begin(payload: String) {
        activePayload = payload
        value = nil
    }

    mutating func complete(with value: Value?, payload: String) {
        guard payload == activePayload else { return }
        self.value = value
    }
}

private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

private actor QRCodeRenderer {
    static let shared = QRCodeRenderer()
    private var context: CIContext?

    func render(payload: String) -> SendableCGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(
            by: CGAffineTransform(scaleX: 10, y: 10)
        )
        let context: CIContext
        if let cachedContext = self.context {
            context = cachedContext
        } else {
            let newContext = CIContext()
            self.context = newContext
            context = newContext
        }
        guard let cgImage = context.createCGImage(
            scaled,
            from: scaled.extent
        ) else {
            return nil
        }
        return SendableCGImage(image: cgImage)
    }
}
