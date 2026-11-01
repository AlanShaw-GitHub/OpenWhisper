import Foundation

enum AudioData {
    static let sampleRate = 24_000
    static func wav(_ pcm: Data) -> Data {
        var result = Data()
        func ascii(_ string: String) { result.append(contentsOf: string.utf8) }
        func u16(_ number: UInt16) { var value = number.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        func u32(_ number: UInt32) { var value = number.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(pcm.count + 36)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}
