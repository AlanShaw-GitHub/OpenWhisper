import Foundation

/// Partial hypotheses are replaced; committed segments are appended in order.
struct ElevenLabsTranscript {
    private var segments: [String] = []
    private(set) var partial = ""
    var hasPendingPartial: Bool { !partial.isEmpty }
    var commitCount: Int { segments.count }
    var text: String { Self.join(segments + [partial]) }

    mutating func consume(_ event: [String: Any]) -> (text: String, final: Bool)? {
        switch event["message_type"] as? String {
        case "partial_transcript":
            guard let value = event["text"] as? String else { return nil }
            partial = value
            return (text, false)
        case "committed_transcript":
            guard let value = event["text"] as? String else { return nil }
            partial = ""
            if !value.isEmpty { segments.append(value) }
            return (text, true)
        default: return nil // Timestamp/entity events must not duplicate committed segments.
        }
    }
    private static func join(_ fragments: [String]) -> String {
        var result = ""
        for fragment in fragments where !fragment.isEmpty {
            if let last = result.last, let first = fragment.first,
               !last.isWhitespace, !first.isWhitespace, !isCJK(last), !isCJK(first),
               !",.!?;:，。！？；：、)]}".contains(first) { result += " " }
            result += fragment
        }
        return result
    }
    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }
    }
}
