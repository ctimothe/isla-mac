import Combine
import Foundation
import IslandCore

/// State machine driven by module activity + hover/click. Timing values are
/// suggested defaults (not locked facts, per the plan) — tune after real-hardware
/// testing.
@MainActor
final class IslandShellViewModel: ObservableObject {
    @Published private(set) var state: IslandState = .collapsed

    private let hoverExpandDelay: Duration = .milliseconds(150)
    private let autoCollapseDelay: Duration = .seconds(2.5)

    private var isPinnedByClick = false
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var cancellable: AnyCancellable?

    init(registry: ModuleRegistry) {
        cancellable = registry.$activeModule
            .receive(on: DispatchQueue.main)
            .sink { [weak self] module in self?.moduleActivityChanged(isActive: module != nil) }
    }

    func mouseEntered() {
        collapseTask?.cancel()
        hoverTask?.cancel()
        hoverTask = Task { [hoverExpandDelay] in
            try? await Task.sleep(for: hoverExpandDelay)
            guard !Task.isCancelled else { return }
            state = .expanded
        }
    }

    func mouseExited() {
        guard !isPinnedByClick else { return }
        scheduleAutoCollapse()
    }

    func handleClick() {
        isPinnedByClick.toggle()
        state = isPinnedByClick ? .expanded : .compact
    }

    private func moduleActivityChanged(isActive: Bool) {
        if isActive, state == .collapsed {
            state = .compact
        }
        if !isActive {
            scheduleAutoCollapse()
        }
    }

    private func scheduleAutoCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { [autoCollapseDelay] in
            try? await Task.sleep(for: autoCollapseDelay)
            guard !Task.isCancelled else { return }
            isPinnedByClick = false
            state = .collapsed
        }
    }
}
