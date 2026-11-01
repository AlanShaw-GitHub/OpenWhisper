import Observation
import Foundation

@Observable @MainActor
final class HUDNotice {
    private(set) var text: String?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func show(_ text: String?, duration: Duration = .seconds(2)) {
        guard let text, !text.isEmpty else { return }
        clear()
        self.text = text
        let id = generation
        expiry = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.generation == id else { return }
            self.text = nil
        }
    }
    func clear() {
        generation = UUID(); expiry?.cancel(); expiry = nil; text = nil
    }
}
