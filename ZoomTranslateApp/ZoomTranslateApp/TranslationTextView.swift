import SwiftUI
import AppKit

struct TranslationTextView: NSViewRepresentable {
    let lines: [String]
    let speakerNames: [String: String]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let docHeight = scrollView.documentView?.bounds.height ?? 0
        let visibleMaxY = scrollView.contentView.bounds.maxY
        let wasAtBottom = (docHeight - visibleMaxY) < 40

        textView.textStorage?.setAttributedString(
            Self.buildAttributedString(lines: lines, speakerNames: speakerNames)
        )

        if wasAtBottom {
            // Dispatch after layout so the scroll reaches the true new bottom
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    // MARK: - Shared attributed string builder (also used for RTF export)

    static func buildAttributedString(lines: [String], speakerNames: [String: String]) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            result.append(styledLine(line, speakerNames: speakerNames))
            if i < lines.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    // MARK: - Private static helpers

    private static let speakerColors: [NSColor] = [
        .systemPurple, .systemTeal, .systemGreen, .systemRed, .systemPink, .systemYellow
    ]

    private static func styledLine(_ line: String, speakerNames: [String: String]) -> NSAttributedString {
        if line.isEmpty {
            return NSAttributedString(string: " ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 4, weight: .regular)
            ])
        }

        if line.hasPrefix("---") {
            return NSAttributedString(string: line, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ])
        }

        if line.hasPrefix("[") {
            let color = speakerColor(in: line)
            let displayLine = substituted(line, speakerNames: speakerNames)

            let attrStr = NSMutableAttributedString(string: displayLine, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ])
            // Color EN:/JP: tag
            let isEN = displayLine.contains("] EN:")
            let tag = isEN ? "EN:" : "JP:"
            let tagColor: NSColor = isEN ? .systemBlue : .systemOrange
            if let range = displayLine.range(of: tag) {
                attrStr.addAttribute(.foregroundColor, value: tagColor, range: NSRange(range, in: displayLine))
            }
            // Color speaker tag (second [...] in line)
            if let color, let range = secondBracketRange(in: displayLine) {
                attrStr.addAttribute(.foregroundColor, value: color, range: NSRange(range, in: displayLine))
            }
            return attrStr
        }

        // Kanji / plain info lines
        return NSAttributedString(string: line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }

    private static func substituted(_ line: String, speakerNames: [String: String]) -> String {
        guard let start = line.range(of: "[Speaker "),
              let end = line.range(of: "]", range: start.upperBound..<line.endIndex)
        else { return line }
        let key = "Speaker " + String(line[start.upperBound..<end.lowerBound])
        guard let name = speakerNames[key], !name.isEmpty else { return line }
        return line.replacingCharacters(in: start.lowerBound..<end.upperBound, with: "[\(name)]")
    }

    private static func speakerColor(in line: String) -> NSColor? {
        guard let start = line.range(of: "[Speaker "),
              let end = line.range(of: "]", range: start.upperBound..<line.endIndex),
              let letter = line[start.upperBound..<end.lowerBound].last,
              let ascii = letter.asciiValue
        else { return nil }
        return speakerColors[Int(ascii - 65) % speakerColors.count]
    }

    private static func secondBracketRange(in line: String) -> Range<String.Index>? {
        guard let firstClose = line.range(of: "]"),
              let secondOpen = line.range(of: "[", range: firstClose.upperBound..<line.endIndex),
              let secondClose = line.range(of: "]", range: secondOpen.upperBound..<line.endIndex)
        else { return nil }
        return secondOpen.lowerBound..<secondClose.upperBound
    }
}
