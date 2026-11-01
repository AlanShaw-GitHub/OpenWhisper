import Foundation

enum TranscriptCleanup {
    private static let terminators: Set<Character> = ["。", ".", "．", "！", "!", "？", "?", "，", ","]
    /// Muse batch transcripts occasionally end with a doubled terminator ("advance..", "材料。。") when the
    /// audio stops abruptly. Exactly two identical trailing marks collapse to one; "..." and longer runs stay.
    static func removingDuplicateTerminalPunctuation(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last, terminators.contains(last) else { return text }
        let run = trimmed.reversed().prefix { $0 == last }.count
        guard run == 2 else { return text }
        return String(trimmed.dropLast())
    }
}
