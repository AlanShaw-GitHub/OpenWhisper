import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Codable, Sendable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Microphones offered in settings; the UID is what settings store, the device ID is what the engine takes.
/// Only real microphones are offered: virtual drivers, aggregates, Continuity (iPhone) capture, AirPlay and Bluetooth
/// are skipped. A Bluetooth input is a hands-free microphone on a headset or on a speaker, and only the Bluetooth
/// device class tells the two apart; reading it needs the Bluetooth privacy permission (without a usage description
/// the system kills the app). Bluetooth headsets stay usable through "System Default".
enum AudioInputDevices {
    /// Turns this app's own executable into the listing helper (handled first thing in `OpenWhisperApp.main`).
    static let helperFlag = "--list-microphones"

    /// The list as a process without voice processing sees it. Once a process enables voice processing, CoreAudio
    /// gives every output device in that process (speakers included) an extra input stream carrying the echo
    /// reference, and every in-process list, CoreAudio's and AVFoundation's alike, then shows speakers as
    /// microphones. So a short-lived copy of this executable, which never opens an audio engine, does the listing.
    static func microphones() async -> [AudioInputDevice] {
        await Task.detached(priority: .userInitiated) { listFromHelper() ?? enumerate() }.value
    }
    /// Helper side: writes the list as JSON to standard output.
    static func printForHelper() {
        FileHandle.standardOutput.write((try? JSONEncoder().encode(enumerate())) ?? Data("[]".utf8))
    }
    private static func listFromHelper() -> [AudioInputDevice]? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = [helperFlag]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // CoreAudio answers in milliseconds; never let a stuck helper hold the list back.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode([AudioInputDevice].self, from: data)
    }
    /// Devices with input channels and an acceptable transport. Only trustworthy in a process that has not enabled
    /// voice processing; the app itself goes through `microphones()`.
    static func enumerate() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard inputChannels(id) > 0, !hiddenTransports.contains(uint32(id, kAudioDevicePropertyTransportType)),
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }
    private static let hiddenTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAirPlay,
        kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless,
        kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
    ]
    private static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid && inputChannels($0) > 0 }
    }
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }
    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
