import Combine
import Foundation

@MainActor
public final class ModuleRegistry: ObservableObject {
    @Published public private(set) var activeModule: (any IslandModule)?

    private let modules: [any IslandModule]
    private var cancellables: Set<AnyCancellable> = []

    public init(modules: [any IslandModule]) {
        self.modules = modules.sorted { $0.priority > $1.priority }
        for module in self.modules {
            module.isActivePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.recompute() }
                .store(in: &cancellables)
        }
        recompute()
    }

    private func recompute() {
        activeModule = modules.first(where: \.isActive)
    }
}
