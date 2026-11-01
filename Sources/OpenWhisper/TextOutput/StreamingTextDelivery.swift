import Foundation

/// Reading the socket must not wait for a slow target application's paste operation.
@MainActor
final class StreamingTextDelivery {
    private let write: (String) async -> Void
    private var pending: String?
    private var worker: Task<Void, Never>?
    init(write: @escaping (String) async -> Void) { self.write = write }
    func submit(_ text: String) {
        pending = text
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let text = self.pending {
                self.pending = nil
                await self.write(text)
            }
            self.worker = nil
        }
    }
    func finish(_ text: String) async {
        submit(text)
        await worker?.value
    }
    func cancel() { pending = nil; worker?.cancel() }
}
