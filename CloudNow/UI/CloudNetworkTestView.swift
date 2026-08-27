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
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text("test_network"))
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 64)
                    .padding(.top, 36)
                    .padding(.bottom, 20)

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
                        .buttonStyle(NetworkTestRowButtonStyle())
                    }
                }
            }
            .navigationTitle("")
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

private struct NetworkTestRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isFocused
                        ? AnyShapeStyle(.white)
                        : AnyShapeStyle(Color.primary.opacity(0.08))
                )
                .clipShape(.rect(cornerRadius: 14))
                .scaleEffect(isFocused && !reduceMotion ? 1.03 : 1)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.15),
                    value: isFocused
                )
        }
    }
}
