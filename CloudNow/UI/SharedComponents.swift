import SwiftUI

struct PassthroughButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct ScrollableText: View {
    let text: String
    var blockCharacterLimit: Int = 360
    var spacing: CGFloat = 24
    var horizontalPadding: CGFloat = 80
    var topPadding: CGFloat = 72
    var bottomPadding: CGFloat = 140
    var font: Font = .callout
    var foregroundStyle: AnyShapeStyle = AnyShapeStyle(.white.opacity(0.85))
    var lineSpacing: CGFloat = 6
    var showsIndicators: Bool = true

    private var focusBlocks: [String] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var blocks: [String] = []
        var current = ""

        // tvOS won't reliably scroll plain text without focusable items, so we split
        // the description into shorter blocks that can each become a focus target.
        for paragraph in paragraphs {
            let candidate = current.isEmpty ? paragraph : current + "\n\n" + paragraph
            if candidate.count > blockCharacterLimit && !current.isEmpty {
                blocks.append(current)
                current = paragraph
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            blocks.append(current)
        }

        return blocks.isEmpty ? [text] : blocks
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: showsIndicators) {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(focusBlocks.enumerated()), id: \.offset) { _, block in
                    Button(action: {}) {
                        Text(block)
                            .font(font)
                            .foregroundStyle(foregroundStyle)
                            .lineSpacing(lineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PassthroughButtonStyle())
                    .focusEffectDisabled()
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
        }
    }
}
