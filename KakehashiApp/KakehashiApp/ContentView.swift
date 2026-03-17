import SwiftUI

struct ContentView: View {
    @StateObject private var vm = TranslationViewModel()
    @EnvironmentObject var store: TranscriptStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            outputPanel
            Divider()
            controlPanel
        }
        .frame(minWidth: 600, minHeight: 500)
        .sheet(isPresented: $vm.showSavePrompt) {
            SaveTranscriptSheet(vm: vm, store: store)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 20) {
            StatusDot(
                label: "Audio Source",
                value: vm.blackholeStatus,
                on: vm.blackholeDetected
            )
            StatusDot(
                label: "Audio",
                value: vm.audioFlowing ? "Flowing" : "Idle",
                on: vm.audioFlowing
            )
            AudioLevelBar(level: vm.audioLevel, threshold: vm.threshold)
            Spacer()
            Button {
                vm.translations.removeAll()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.translations.isEmpty)
            Button {
                vm.showSavePrompt = true
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.translations.isEmpty)
            Button {
                openWindow(id: "history")
            } label: {
                Label("History", systemImage: "clock")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Translation output

    private var outputPanel: some View {
        TranslationTextView(lines: vm.translations, speakerNames: vm.speakerNames)
            .overlay(alignment: .topTrailing) { copyAllButton }
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    if vm.isProcessingBacklog {
                        ProcessingBacklogToast()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if vm.isDropping {
                        DroppingToast()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, 10)
            }
            .animation(.easeInOut(duration: 0.25), value: vm.isDropping)
            .animation(.easeInOut(duration: 0.25), value: vm.isProcessingBacklog)
    }

    private var copyAllButton: some View {
        Button { vm.copyAll() } label: {
            Label("Copy All", systemImage: "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .disabled(vm.translations.isEmpty)
    }

    // MARK: - Controls

    private var controlPanel: some View {
        VStack(spacing: 10) {
            // Row 1: Model picker + Start/Stop
            HStack(alignment: .center, spacing: 16) {
                Text("Model:")
                    .frame(width: 130, alignment: .trailing)

                Picker("", selection: $vm.selectedModel) {
                    ForEach(vm.models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                .disabled(vm.isRunning || vm.isStopping)

                Spacer()

                Button {
                    if vm.isRunning { vm.stop() }
                    else if !vm.isStopping { vm.start() }
                } label: {
                    Text(vm.isStopping ? "Stopping…" : vm.isRunning ? "Stop" : "Start")
                        .frame(width: 80)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(vm.isRunning || vm.isStopping ? .red : .accentColor)
                .disabled(vm.isStopping)
                .keyboardShortcut(vm.isRunning ? .escape : .return, modifiers: [])
            }

            // Row 2: Show original + Debug
            HStack {
                Spacer()
                Toggle("Debug (raw output)", isOn: $vm.debugMode)
                    .foregroundStyle(vm.debugMode ? .orange : .secondary)
                Spacer().frame(width: 16)
                Toggle("Show original text", isOn: $vm.showOriginalText)
                    .onChange(of: vm.showOriginalText) { _ in vm.sendShowOriginal() }
            }

            // Row 3: Silence threshold
            HStack {
                Text("Silence Threshold:")
                    .frame(width: 130, alignment: .trailing)
                Slider(value: $vm.threshold, in: 0.0001...0.01)
                    .onChange(of: vm.threshold) { _ in vm.sendSilenceThreshold() }
                Text(String(format: "%.4f", vm.threshold))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60)
            }

            // Row 3: Chunk size
            HStack {
                Text("Chunk Size:")
                    .frame(width: 130, alignment: .trailing)
                Slider(value: $vm.chunkSize, in: 2...8, step: 1)
                    .onChange(of: vm.chunkSize) { _ in vm.sendChunkSize() }
                Text("\(Int(vm.chunkSize)) sec")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60)
            }

            // Row 4: Speaker grouping threshold (adjustable while running)
            HStack {
                Text("Speaker Grouping:")
                    .frame(width: 130, alignment: .trailing)
                Slider(value: $vm.speakerThreshold, in: 0.1...0.9)
                    .onChange(of: vm.speakerThreshold) { _ in vm.sendSpeakerThreshold() }
                Text(String(format: "%.2f", vm.speakerThreshold))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60)
            }

            // Row 5: HuggingFace token for speaker tracking
            HStack {
                Text("HF Token:")
                    .frame(width: 130, alignment: .trailing)
                SecureField("Paste token for speaker tracking (optional)", text: $vm.hfToken)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vm.isRunning || vm.isStopping)
            }

            // Speaker name rows — appear as speakers are detected
            if !vm.discoveredSpeakers.isEmpty {
                Divider()
                ForEach(vm.discoveredSpeakers, id: \.self) { speaker in
                    HStack {
                        Text("\(speaker):")
                            .frame(width: 130, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        TextField("Custom name…", text: Binding(
                            get: { vm.speakerNames[speaker] ?? "" },
                            set: { vm.speakerNames[speaker] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .padding(16)
    }
}

// MARK: - Toasts

private struct ProcessingBacklogToast: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.7)
            Text("Reviewing queued audio…")
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4)
    }
}

private struct DroppingToast: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Dropping audio — model too slow for chunk size")
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4)
    }
}

// MARK: - Audio level bar

private struct AudioLevelBar: View {
    let level: Double
    let threshold: Double

    // Map amplitude to 0…1 on a log scale (0.0001 → 0, 0.1 → 0.75, 1.0 → 1.0)
    private func normalized(_ val: Double) -> Double {
        let clamped = max(0.000001, val)
        return min(1.0, max(0.0, (log10(clamped) + 4.0) / 4.0))
    }

    private var fill: Double { normalized(level) }
    private var thresholdPos: Double { normalized(threshold) }

    private var barColor: Color {
        level == 0 ? .gray.opacity(0.3) : (level >= threshold ? .green : .orange)
    }

    var body: some View {
        HStack(spacing: 5) {
            Text("Level:")
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.gray.opacity(0.4), lineWidth: 0.5)
                        )
                    // Fill
                    if fill > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor)
                            .frame(width: max(4, geo.size.width * fill))
                            .animation(.linear(duration: 0.15), value: fill)
                    }
                    // Threshold marker
                    Rectangle()
                        .fill(Color.red.opacity(0.8))
                        .frame(width: 2)
                        .offset(x: geo.size.width * thresholdPos - 1)
                }
            }
            .frame(width: 100, height: 10)
            Text(level > 0 ? String(format: "%.4f", level) : "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
        }
    }
}

// MARK: - Status dot

private struct StatusDot: View {
    let label: String
    let value: String
    let on: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(on ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text("\(label): \(value)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Save transcript sheet

private struct SaveTranscriptSheet: View {
    @ObservedObject var vm: TranslationViewModel
    let store: TranscriptStore

    @State private var name: String

    init(vm: TranslationViewModel, store: TranscriptStore) {
        self.vm = vm
        self.store = store
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h:mm a"
        _name = State(initialValue: formatter.string(from: vm.sessionStartDate ?? Date()))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Save Transcript")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
            HStack(spacing: 12) {
                Button("Discard") {
                    vm.showSavePrompt = false
                }
                Button("Save") {
                    let transcript = Transcript(
                        id: UUID(),
                        name: name.isEmpty ? "Untitled" : name,
                        startDate: vm.sessionStartDate ?? Date(),
                        lines: vm.translations,
                        speakerNames: vm.speakerNames
                    )
                    store.save(transcript)
                    vm.showSavePrompt = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding(32)
    }
}

#Preview {
    ContentView()
        .environmentObject(TranscriptStore())
}
