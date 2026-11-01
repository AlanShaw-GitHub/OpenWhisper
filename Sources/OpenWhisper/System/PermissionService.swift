import AppKit
import AVFoundation
import ApplicationServices

@Observable @MainActor
final class PermissionService {
    var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    var accessibility = AXIsProcessTrusted()
    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = AXIsProcessTrusted()
    }
    func requestMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else if !microphone {
            openPrivacy("Microphone")
        }
        refresh()
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        openPrivacy("Accessibility")
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
