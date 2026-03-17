import Foundation

struct Transcript: Identifiable, Codable {
    let id: UUID
    var name: String
    let startDate: Date
    let lines: [String]
    let speakerNames: [String: String]
}
