import AppKit
import UniformTypeIdentifiers

class TranscriptStore: ObservableObject {
    @Published var transcripts: [Transcript] = []

    private let dataURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kakehashi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dataURL = dir.appendingPathComponent("transcripts.json")
        load()
    }

    func save(_ transcript: Transcript) {
        transcripts.insert(transcript, at: 0)
        persist()
    }

    func delete(_ transcript: Transcript) {
        transcripts.removeAll { $0.id == transcript.id }
        persist()
    }

    func exportRTF(_ transcript: Transcript) {
        let attrStr = TranslationTextView.buildAttributedString(
            lines: transcript.lines,
            speakerNames: transcript.speakerNames
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.rtf]
        panel.nameFieldStringValue = transcript.name + ".rtf"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let range = NSRange(location: 0, length: attrStr.length)
            let data = try? attrStr.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            try? data?.write(to: url)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: dataURL) else { return }
        transcripts = (try? JSONDecoder().decode([Transcript].self, from: data)) ?? []
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(transcripts) {
            try? data.write(to: dataURL)
        }
    }
}
