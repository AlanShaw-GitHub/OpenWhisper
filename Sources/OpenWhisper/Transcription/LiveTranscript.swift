import Foundation

/// Keeps provider deltas/cumulative hypotheses distinct and orders OpenAI items by creation.
struct LiveTranscript {
    private var order: [String] = []
    private var texts: [String: String] = [:]
    private(set) var text = ""
    private var elevenLabs = ElevenLabsTranscript()
    var elevenLabsHasPartial: Bool { elevenLabs.hasPendingPartial }
    var elevenLabsCommits: Int { elevenLabs.commitCount }
    mutating func consume(_ event: [String: Any], provider: Provider) -> (text: String, final: Bool)? {
        if provider == .elevenlabs {
            guard let update = elevenLabs.consume(event) else { return nil }
            text = update.text; return update
        }
        let type = event["type"] as? String ?? ""
        if provider == .muse {
            guard type == "transcript", let next = event["transcript"] as? String else { return nil }
            text = next
            return (next, event["final"] as? Bool == true)
        }
        if type == "input_audio_buffer.committed", let id = event["item_id"] as? String {
            insert(id, after: event["previous_item_id"] as? String)
            return nil
        }
        guard let id = event["item_id"] as? String else { return nil }
        if !order.contains(id) { order.append(id) }
        switch type {
        case "conversation.item.input_audio_transcription.delta": texts[id, default: ""] += event["delta"] as? String ?? ""
        case "conversation.item.input_audio_transcription.completed": texts[id] = event["transcript"] as? String ?? ""
        default: return nil
        }
        text = order.compactMap { texts[$0] }.joined()
        return (text, type == "conversation.item.input_audio_transcription.completed")
    }
    private mutating func insert(_ id: String, after previous: String?) {
        order.removeAll { $0 == id }
        if let previous, let index = order.firstIndex(of: previous) { order.insert(id, at: index + 1) }
        else { order.insert(id, at: 0) }
    }
}
