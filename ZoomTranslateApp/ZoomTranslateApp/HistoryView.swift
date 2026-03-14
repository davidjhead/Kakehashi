import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var store: TranscriptStore
    @State private var selectedId: UUID?
    @State private var transcriptToDelete: Transcript?

    private var selected: Transcript? {
        store.transcripts.first { $0.id == selectedId }
    }

    var body: some View {
        NavigationSplitView {
            List(store.transcripts, selection: $selectedId) { transcript in
                VStack(alignment: .leading, spacing: 3) {
                    Text(transcript.name)
                        .font(.body)
                    Text(transcript.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(transcript.id)
            }
            .navigationTitle("History")
            .frame(minWidth: 220)
        } detail: {
            if let transcript = selected {
                TranslationTextView(lines: transcript.lines, speakerNames: transcript.speakerNames)
                    .toolbar {
                        ToolbarItem {
                            Button {
                                store.exportRTF(transcript)
                            } label: {
                                Label("Export RTF", systemImage: "square.and.arrow.up")
                            }
                        }
                        ToolbarItem {
                            Button(role: .destructive) {
                                transcriptToDelete = transcript
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
            } else {
                Text("Select a transcript")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(
            "Delete Transcript?",
            isPresented: Binding(get: { transcriptToDelete != nil }, set: { if !$0 { transcriptToDelete = nil } }),
            presenting: transcriptToDelete
        ) { t in
            Button("Delete", role: .destructive) {
                if selectedId == t.id { selectedId = nil }
                store.delete(t)
                transcriptToDelete = nil
            }
            Button("Cancel", role: .cancel) { transcriptToDelete = nil }
        } message: { t in
            Text("\"\(t.name)\" will be permanently deleted. This cannot be undone.")
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
