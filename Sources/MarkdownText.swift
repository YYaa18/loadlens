import SwiftUI

/// Lightweight block-level Markdown for chat replies: paragraphs, bullet / numbered lists,
/// headings (shown as bold lines) and fenced code. Inline styles use Foundation's parser.
/// Safe to re-render on every streamed chunk.
struct MarkdownText: View {
    let text: String
    var fontSize: CGFloat = 13

    private enum Block: Hashable {
        case paragraph(String)
        case heading(String)
        case bullet(String)
        case numbered(String, String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let line):
            inline(line)
        case .heading(let line):
            inline(line).fontWeight(.semibold)
        case .bullet(let line):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(Brand.orange)
                    .frame(width: 5, height: 5)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                inline(line)
            }
            .padding(.leading, 2)
        case .numbered(let number, let line):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number + ".")
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(Brand.orange)
                    .monospacedDigit()
                inline(line)
            }
            .padding(.leading, 1)
        case .code(let code):
            Text(code)
                .font(.system(size: fontSize - 1.5, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        }
    }

    private func inline(_ line: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: line, options: options)) ?? AttributedString(line)
        return Text(attributed)
            .font(.system(size: fontSize))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil

        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if let open = code {
                    result.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(rawLine)
                continue
            }

            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                result.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                result.append(.bullet(String(line.dropFirst(2))))
            } else if let match = numberedPrefix(line) {
                flush()
                result.append(.numbered(match.0, match.1))
            } else {
                paragraph.append(line)
            }
        }
        if let open = code { result.append(.code(open.joined(separator: "\n"))) }
        flush()
        return result
    }

    private func numberedPrefix(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix("、") || rest.hasPrefix(") ") else { return nil }
        let body = rest.hasPrefix("、") ? rest.dropFirst(1) : rest.dropFirst(2)
        return (String(digits), String(body).trimmingCharacters(in: .whitespaces))
    }
}
