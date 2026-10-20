import SwiftUI

struct GameStoreView: View {
    let gameTitle: String
    let storeName: String
    let url: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            Text(L10n.format("view_in_store", storeName))
                .font(.title.weight(.semibold))
            Text(gameTitle)
                .font(.title3)
                .multilineTextAlignment(.center)
            QRCodeView(payload: url.absoluteString)
                .frame(width: 280, height: 280)
                .clipShape(.rect(cornerRadius: 16))
                .accessibilityLabel(L10n.text("scan_qr_or_go_to"))
                .accessibilityValue(url.absoluteString)
                .accessibilityIdentifier("game-store-qr.code")
            Text(L10n.text("game_store_phone_description"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 1100)
            Text(url.absoluteString)
                .font(.callout.monospaced())
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button(L10n.text("close")) {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("game-store-qr.close")
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game-store-qr")
        .onExitCommand {
            dismiss()
        }
        .blocksGlobalControllerNavigation()
    }
}
