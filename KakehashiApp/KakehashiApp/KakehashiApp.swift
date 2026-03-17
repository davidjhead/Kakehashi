import SwiftUI
import AVFoundation

@main
struct KakehashiApp: App {
    @StateObject private var store = TranscriptStore()

    init() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                print("Microphone access denied — audio capture will not work.")
            }
        }
    }

    var body: some Scene {
        WindowGroup("Kakehashi") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 720, height: 620)

        Window("History", id: "history") {
            HistoryView()
                .environmentObject(store)
        }
        .defaultSize(width: 900, height: 600)
    }
}
