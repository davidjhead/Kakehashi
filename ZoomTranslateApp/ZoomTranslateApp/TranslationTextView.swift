import SwiftUI
import AppKit

// MARK: - Custom NSTextView with right-click Copy Block

private class TranslationNSTextView: NSTextView {
    /// Lines array kept in sync by the representable so the menu handler can use it.
    var currentLines: [String] = []

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()

        // Find the character index under the right-click point
        let pt = convert(event.locationInWindow, from: nil)
        guard let layout = layoutManager, let container = textContainer else { return menu }
        let charIdx = layout.characterIndex(for: pt, in: container,
                                             fractionOfDistanceBetweenInsertionPoints: nil)

        // Walk the full attributed string to find which line range contains charIdx
        guard let storage = textStorage else { return menu }
        let full = storage.string as NSString
        var blockStart = charIdx
        var blockEnd   = charIdx

        // Walk backward to find the start of the block (line beginning with "[")
        var lineRange = NSRange(location: 0, length: 0)
        full.getLineStart(nil, end: nil, contentsEnd: nil, for: NSRange(location: charIdx, length: 0))
        var search = charIdx
        while search > 0 {
            full.getLineStart(&lineRange.location, end: nil, contentsEnd: nil,
                              for: NSRange(location: search, length: 0))
            let lineStr = full.substring(with: NSRange(location: lineRange.location,
                                                        length: min(1, full.length - lineRange.location)))
            if lineStr == "[" { blockStart = lineRange.location; break }
            if search == lineRange.location { break }
            search = max(0, lineRange.location - 1)
        }

        // Walk forward to find the blank line that ends the block
        blockEnd = charIdx
        var fwdPos = charIdx
        while fwdPos < full.length {
            var end = 0, contentsEnd = 0
            full.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: fwdPos, length: 0))
            let lineContent = full.substring(with: NSRange(location: fwdPos,
                                                            length: contentsEnd - fwdPos))
            blockEnd = end
            if lineContent.trimmingCharacters(in: .whitespaces).isEmpty && fwdPos != charIdx { break }
            if end == fwdPos { break }
            fwdPos = end
        }

        let blockText = full.substring(with: NSRange(location: blockStart,
                                                      length: blockEnd - blockStart))
                             .trimmingCharacters(in: .whitespacesAndNewlines)

        if !blockText.isEmpty {
            let item = NSMenuItem(title: "Copy Block", action: #selector(copyBlock(_:)),
                                  keyEquivalent: "")
            item.representedObject = blockText
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func copyBlock(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct TranslationTextView: NSViewRepresentable {
    let lines: [String]
    let speakerNames: [String: String]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = TranslationNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                        height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TranslationNSTextView else { return }
        textView.currentLines = lines

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
