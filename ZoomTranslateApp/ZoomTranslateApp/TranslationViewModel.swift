import AppKit
import Combine
import SwiftUI

class TranslationViewModel: ObservableObject {

    // MARK: - Published state

    @Published var translations: [String] = []
    @Published var isRunning = false
    @Published var isStopping = false          // SIGTERM sent, awaiting backlog + exit
    @Published var isProcessingBacklog = false

    @Published var blackholeStatus = "Unknown"
    @Published var blackholeDetected = false
    @Published var audioFlowing = false
    @Published var isDropping = false

    private var dropTimer: Timer?

    // MARK: - Settings (disabled while running)

    @Published var selectedModel = "large-v3-turbo"
    @Published var threshold: Double = 0.002
    @Published var chunkSize: Double = 4
    @AppStorage("hfToken") var hfToken: String = ""

    // MARK: - Settings (adjustable while running)

    @Published var speakerThreshold: Double = 0.65
    @Published var showOriginalText: Bool = true

    // MARK: - Speaker names

    @Published var discoveredSpeakers: [String] = []   // ordered, e.g. ["Speaker A", "Speaker B"]
    @Published var speakerNames: [String: String] = [:] // "Speaker A" → "Alice"

    let models = ["small", "medium", "large-v3", "large-v3-turbo"]

    // MARK: - Clipboard helpers

    var fullText: String {
        translations.map { $0.isEmpty ? "" : $0 }.joined(separator: "\n")
    }

    func copyAll() { copy(fullText) }
    func copyLine(_ line: String) { copy(line) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Private

    @Published var showSavePrompt = false
    private(set) var sessionStartDate: Date?

    private var process: Process?
    private var outputPipe: Pipe?
    private var inputPipe: Pipe?
    private var replaceNextBlock = false

    // MARK: - Control

    func start() {
        translations.removeAll()
        discoveredSpeakers.removeAll()
        sessionStartDate  = Date()
        showSavePrompt    = false
        blackholeStatus   = "Checking…"
        blackholeDetected = false
        audioFlowing      = false
        isDropping        = false
        isProcessingBacklog = false

        let home   = NSHomeDirectory()
        let python = "\(home)/zoom-translate/bin/python"
        let script = "\(home)/zoom-translate/translate.py"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        var args = [
            "-u", script,
            "--model",      selectedModel,
            "--threshold",  String(format: "%.6f", threshold),
            "--chunk-size", String(Int(chunkSize)),
            showOriginalText ? "--show-original" : "--no-show-original"
        ]
        if !hfToken.isEmpty {
            args += ["--hf-token", hfToken]
        }
        proc.arguments = args

        let inPipe = Pipe()
        proc.standardInput = inPipe

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.components(separatedBy: "\n")
            DispatchQueue.main.async {
                for line in lines { self?.handleLine(line) }
            }
        }

        // Cleanup runs when Python actually exits (after backlog is processed)
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self?.process    = nil
                self?.outputPipe = nil
                self?.inputPipe  = nil
                self?.isRunning  = false
                self?.isStopping = false
                self?.isProcessingBacklog = false
                self?.audioFlowing = false
            }
        }

        do {
            try proc.run()
            process    = proc
            outputPipe = pipe
            inputPipe  = inPipe
            isRunning  = true
        } catch {
            translations.append("[Error] Could not launch Python: \(error.localizedDescription)")
            translations.append("[Error] Verify path: \(python)")
        }
    }

    func sendSpeakerThreshold() {
        send("speaker_threshold:\(String(format: "%.2f", speakerThreshold))")
    }

    func sendSilenceThreshold() {
        send("silence_threshold:\(String(format: "%.6f", threshold))")
    }

    func sendShowOriginal() {
        send("show_original:\(showOriginalText)")
    }

    func sendChunkSize() {
        send("chunk_size:\(Int(chunkSize))")
    }

    private func send(_ command: String) {
        guard let pipe = inputPipe,
              let data = (command + "\n").data(using: .utf8) else { return }
        pipe.fileHandleForWriting.write(data)
    }

    /// Sends SIGTERM. Python catches it, processes the dropped-chunk backlog,
    /// then exits. The readabilityHandler keeps streaming until the process dies.
    func stop() {
        guard isRunning else { return }
        isRunning  = false
        isStopping = true
        replaceNextBlock = false
        dropTimer?.invalidate()
        isDropping = false
        process?.terminate()
        // Do NOT nil out process/pipe here — terminationHandler does that
        // after the backlog output has been fully received.
    }

    // MARK: - Output parsing

    private func handleLine(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve empty lines as block separators (needed for clean copy/paste),
        // but only if the last line wasn't already empty
        if line.isEmpty {
            if translations.last?.isEmpty == false {
                translations.append("")
            }
            return
        }
        guard !line.hasPrefix("objc[") else { return }
        guard !line.hasPrefix("---") else { return }
        guard !line.contains("Detected language:") else { return }
        guard !line.contains("%|") else { return }           // tqdm progress bars
        guard !line.contains("unauthenticated requests") else { return }
        guard !line.contains("tie_word_embeddings") else { return }
        guard !line.contains("tied weights") else { return }

        if line.hasPrefix("[STATUS]") {
            let payload = line.dropFirst("[STATUS]".count).trimmingCharacters(in: .whitespaces)
            switch true {
            case payload == "blackhole:detected":
                blackholeStatus   = "Detected"
                blackholeDetected = true
            case payload == "blackhole:not_found":
                blackholeStatus   = "Not Found"
                blackholeDetected = false
            case payload == "audio:flowing":
                audioFlowing = true
            case payload == "replace_last_block":
                replaceNextBlock = true
            case payload == "backlog_complete":
                isProcessingBacklog = false
            case payload.hasPrefix("dropping:"):
                isDropping = true
                dropTimer?.invalidate()
                dropTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                    self?.isDropping = false
                }
            case payload.hasPrefix("processing_backlog:"):
                isProcessingBacklog = true
            default:
                break
            }
            return
        }

        // Fallback detection from human-readable startup lines
        if line.contains("Audio source:") {
            blackholeStatus   = "Detected"
            blackholeDetected = true
        } else if line.contains("Capturing audio") {
            audioFlowing = true
        }

        if replaceNextBlock && line.hasPrefix("[") {
            if let blockStart = translations.lastIndex(where: { $0.hasPrefix("[") }) {
                translations.removeSubrange(blockStart...)
            }
            replaceNextBlock = false
        }

        translations.append(line)
        if translations.count > 2000 {
            translations.removeFirst(translations.count - 2000)
        }

        // Track newly discovered speakers
        if line.hasPrefix("["),
           let start = line.range(of: "[Speaker "),
           let end = line.range(of: "]", range: start.upperBound..<line.endIndex) {
            let speaker = "Speaker " + String(line[start.upperBound..<end.lowerBound])
            if !discoveredSpeakers.contains(speaker) {
                discoveredSpeakers.append(speaker)
            }
        }
    }
}
