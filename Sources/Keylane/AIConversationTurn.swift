import Foundation
import KeylaneCore

/// Shared persisted message contract. Legacy Quick AI files are read once into attachments.
struct AIConversationTurn: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let question: String
    var answer = ""
    var complete = false
    var attachments: [AIConversationAttachment]?
    var progress: AIResponseProgress?
    var requestText: String { AIConversationAttachment.requestText(question: question, attachments: attachments ?? []) }

    private enum CodingKeys: String, CodingKey { case id, question, answer, complete, attachments, files, progress }
    init(question: String, attachments: [AIConversationAttachment]? = nil, progress: AIResponseProgress? = nil) {
        self.question = question
        self.attachments = attachments
        self.progress = progress
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        question = try values.decode(String.self, forKey: .question)
        answer = try values.decodeIfPresent(String.self, forKey: .answer) ?? ""
        complete = try values.decodeIfPresent(Bool.self, forKey: .complete) ?? false
        var restored = try values.decodeIfPresent([AIConversationAttachment].self, forKey: .attachments) ?? []
        let files = try values.decodeIfPresent([AIFileAttachment].self, forKey: .files) ?? []
        restored += files.map(\.attachment).filter { file in !restored.contains { $0.id == file.id } }
        attachments = restored.isEmpty ? nil : restored
        progress = try values.decodeIfPresent(AIResponseProgress.self, forKey: .progress)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(question, forKey: .question)
        try values.encode(answer, forKey: .answer)
        try values.encode(complete, forKey: .complete)
        try values.encodeIfPresent(attachments, forKey: .attachments)
        try values.encodeIfPresent(progress, forKey: .progress)
    }
}
