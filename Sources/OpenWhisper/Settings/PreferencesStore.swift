import Foundation
import Observation

@Observable @MainActor
final class PreferencesStore {
    var configuration: Configuration {
        didSet {
            if configuration.interfaceLanguage != oldValue.interfaceLanguage { Localization.shared.use(configuration.interfaceLanguage) }
            save()
        }
    }
    #if OPENWHISPER_DIAGNOSTICS
    /// `--demo-settings`: screenshots use a fixed configuration that is never written to disk.
    private let persists = !CommandLine.arguments.contains("--demo-settings")
    #else
    private let persists = true
    #endif
    init() {
        var config = Configuration()
        #if OPENWHISPER_DIAGNOSTICS
        if !persists {
            config.mode = .streaming
            config.openAISettings.keywordText = "Acme, eSIM, Kubernetes"
            config.postProcessing.enabled = true
            configuration = config
            Localization.shared.use(config.interfaceLanguage)
            return
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode(Configuration.self, from: data) {
            config = saved
        }
        configuration = config
        Localization.shared.use(config.interfaceLanguage)
        save()
    }
    private static let key = "configuration.v1"
    private func save() {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
