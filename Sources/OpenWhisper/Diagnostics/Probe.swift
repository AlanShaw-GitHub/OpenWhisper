import Foundation
#if OPENWHISPER_DIAGNOSTICS
import OSLog
#endif

/// Start-up milestones for the diagnostics build (`script/build_and_run.sh --diagnostics`, which defines
/// `OPENWHISPER_DIAGNOSTICS`). In every other build these calls are empty, so the app neither measures nor logs them.
@MainActor
enum Probe {
    #if OPENWHISPER_DIAGNOSTICS
    /// Milliseconds since the shortcut press, by milestone; read by `DiagnosticRunner`.
    static var milestones: [String: Int] = [:]
    private static let logger = Logger(subsystem: "com.alan.wisper", category: "probe")
    #endif
    @inline(__always) static func reset() {
        #if OPENWHISPER_DIAGNOSTICS
        milestones = [:]
        #endif
    }
    @inline(__always) static func mark(_ name: String, since start: ContinuousClock.Instant) {
        #if OPENWHISPER_DIAGNOSTICS
        let milliseconds = Int(start.duration(to: .now).seconds * 1000)
        milestones[name] = milliseconds
        logger.notice("\(name, privacy: .public) \(milliseconds) ms")
        #endif
    }
    @inline(__always) static func log(_ message: @autoclosure () -> String) {
        #if OPENWHISPER_DIAGNOSTICS
        let text = message()
        logger.notice("\(text, privacy: .public)")
        #endif
    }
}
