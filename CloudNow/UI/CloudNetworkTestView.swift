import Foundation
import SwiftUI

/// Provider-neutral network-test chrome. Providers resolve the best confirmed
/// endpoint while sampling, presentation, thresholds, focus, and accessibility
/// remain identical.
struct CloudNetworkTestView: View {
    @Environment(\.dismiss) private var dismiss

    let resolveTarget: @Sendable () async -> CloudNetworkTestTarget

    @State private var isRunning = true
    @State private var routedTo: String?
    @State private var pingMs: Double?
    @State private var jitterMs: Double?
    @State private var lossPercent: Double?

    private static let sampleCount = 10

    var body: some View {
        NavigationStack {
            ServerPickerScreen(title: L10n.text("test_network")) {
                List {
                    Section {
                        if let routedTo {
                            LabeledContent(L10n.text("routed_to"), value: routedTo)
                        }
                        LabeledContent(L10n.text("rtt")) {
                            resultText(
                                pingMs.map { String(format: "%.0f ms", $0) },
                                color: pingMs.map(pingColor)
                            )
                        }
                        LabeledContent(L10n.text("jitter")) {
                            resultText(
                                jitterMs.map { String(format: "%.1f ms", $0) },
                                color: nil
                            )
                        }
                        LabeledContent(L10n.text("loss")) {
                            resultText(
                                lossPercent.map { String(format: "%.0f %%", $0) },
                                color: lossPercent.map { $0 > 0 ? .orange : .green }
                            )
                        }
                    } footer: {
                        if isRunning {
                            Label(L10n.text("test_running"), systemImage: "wifi")
                        }
                    }

                    Section {
                        Button {
                            dismiss()
                        } label: {
                            Text(L10n.text("close"))
                        }
                        .buttonStyle(ServerRowButtonStyle())
                    }
                }
            }
            .task {
                await run()
            }
        }
        .blocksGlobalControllerNavigation()
    }

    @ViewBuilder
    private func resultText(_ value: String?, color: Color?) -> some View {
        if let value {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(color ?? .primary)
        } else {
            Text("…")
                .foregroundStyle(.secondary)
        }
    }

    private func run() async {
        let target = await resolveTarget()
        guard !Task.isCancelled else { return }
        routedTo = target.displayName

        _ = await probe(target.address)

        var samples: [Double] = []
        var failures = 0
        for _ in 0 ..< Self.sampleCount {
            guard !Task.isCancelled else { return }
            if let ms = await probe(target.address) {
                samples.append(ms)
                pingMs = samples.reduce(0, +) / Double(samples.count)
            } else {
                failures += 1
            }
            lossPercent = Double(failures) / Double(Self.sampleCount) * 100
        }

        if samples.count > 1 {
            let differences = zip(samples.dropFirst(), samples).map { abs($0 - $1) }
            jitterMs = differences.reduce(0, +) / Double(differences.count)
        } else if !samples.isEmpty {
            jitterMs = 0
        }
        isRunning = false
    }

    private func probe(_ urlString: String) async -> Double? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let start = ContinuousClock.now
        do {
            _ = try await URLSession.shared.data(for: request)
            let duration = start.duration(to: .now)
            return Double(duration.components.seconds) * 1000
                + Double(duration.components.attoseconds) / 1e15
        } catch {
            return nil
        }
    }

    private func pingColor(_ milliseconds: Double) -> Color {
        if milliseconds < 30 {
            return .green
        }
        if milliseconds < 80 {
            return .yellow
        }
        if milliseconds < 150 {
            return .orange
        }
        return .red
    }
}
