import XCTest

/// macOS kills an app the moment it touches privacy-protected data whose usage description is missing from
/// Info.plist (a Bluetooth device-class lookup once crashed the settings panel this way).
final class PrivacyTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// Frameworks whose use needs a usage description, by the Info.plist key they need.
    private static let protected: [String: String] = [
        "IOBluetooth": "NSBluetoothAlwaysUsageDescription", "CoreBluetooth": "NSBluetoothAlwaysUsageDescription",
        "Contacts": "NSContactsUsageDescription", "EventKit": "NSCalendarsUsageDescription",
        "Photos": "NSPhotoLibraryUsageDescription", "CoreLocation": "NSLocationUsageDescription",
        "Speech": "NSSpeechRecognitionUsageDescription", "ScreenCaptureKit": "NSScreenCaptureUsageDescription",
    ]

    func testEveryProtectedFrameworkHasAUsageDescription() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist")) as? [String: Any])
        XCTAssertFalse((plist["NSMicrophoneUsageDescription"] as? String ?? "").isEmpty, "recording needs the microphone description")
        let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (framework, key) in Self.protected where text.contains("import \(framework)\n") {
                XCTAssertNotNil(plist[key], "\(file.lastPathComponent) imports \(framework) but Info.plist has no \(key)")
            }
        }
        let package = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        for (framework, key) in Self.protected where package.contains("linkedFramework(\"\(framework)\")") {
            XCTAssertNotNil(plist[key], "Package.swift links \(framework) but Info.plist has no \(key)")
        }
    }
}
