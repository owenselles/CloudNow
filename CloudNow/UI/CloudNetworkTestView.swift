import Foundation
import SwiftUI

/// Provider-neutral network-test chrome. Providers resolve the best confirmed
/// endpoint while sampling, presentation, thresholds, focus, and accessibility
/// remain identical.
struct CloudNetworkTestView: View {
    @Environment(\.dismiss) private var dismiss

    private let resolveTarget: @Sendable () async -> CloudNetworkTestTarget
    private let probe: @Sendable (String) async -> Double?

    @State private var isRunning = true
    @State private var testTarget: CloudNetworkTestTarget?
    @State private var responseTimeMs: Double?
    @State private var responseVariationMs: Double?
    @State private var failurePercent: Double?

    private static let sampleCount = 10

    init(
        probe: (@Sendable (String) async -> Double?)? = nil,
        resolveTarget: @escaping @Sendable () async -> CloudNetworkTestTarget
    ) {
        self.resolveTarget = resolveTarget
        self.probe = probe ?? Self.measureHTTPResponseTime
    }

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
                        if let testTarget {
                            let title = L10n.text("network_test_endpoint")
                            let host = URL(string: testTarget.address)?.host ?? testTarget.address
                            let name = testTarget.displayName ?? ""
                            VStack(alignment: .trailing, spacing: 4) {
                                LabeledContent(title, value: name)
                                Text(verbatim: host)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(title)
                            .accessibilityValue(name.isEmpty ? host : "\(name), \(host)")
                            .accessibilityIdentifier("network-test.endpoint")
                        }
                        measurementRow(
                            L10n.text("network_test_response_time"),
                            value: responseTimeMs.map { String(format: "%.0f ms", $0) },
                            color: responseTimeMs.map(responseTimeColor),
                            identifier: "network-test.response-time"
                        )
                        measurementRow(
                            L10n.text("network_test_response_variation"),
                            value: responseVariationMs.map { String(format: "%.1f ms", $0) },
                            identifier: "network-test.response-variation"
                        )
                        measurementRow(
                            L10n.text("network_test_failed_requests"),
                            value: failurePercent.map { String(format: "%.0f %%", $0) },
                            color: failurePercent.map { $0 > 0 ? .orange : .green },
                            identifier: "network-test.failed-requests"
                        )
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

    private func measurementRow(
        _ title: String,
        value: String?,
        color: Color? = nil,
        identifier: String
    ) -> some View {
        let text = value ?? (isRunning ? "…" : "–")
        return LabeledContent(title) {
            Text(text)
                .monospacedDigit()
                .foregroundStyle(value == nil ? Color.secondary : color ?? .primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text)
        .accessibilityIdentifier(identifier)
    }

    private func run() async {
        let target = await resolveTarget()
        guard !Task.isCancelled else { return }
        testTarget = target

        _ = await probe(target.address)

        var samples: [Double] = []
        var failures = 0
        for attempt in 1 ... Self.sampleCount {
            guard !Task.isCancelled else { return }
            if let ms = await probe(target.address) {
                samples.append(ms)
                responseTimeMs = samples.reduce(0, +) / Double(samples.count)
            } else {
                failures += 1
            }
            failurePercent = Double(failures) / Double(attempt) * 100
        }

        if samples.count > 1 {
            let differences = zip(samples.dropFirst(), samples).map { abs($0 - $1) }
            responseVariationMs = differences.reduce(0, +) / Double(differences.count)
        }
        isRunning = false
    }

    private nonisolated static func measureHTTPResponseTime(_ urlString: String) async -> Double? {
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

    private func responseTimeColor(_ milliseconds: Double) -> Color {
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
