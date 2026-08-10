import Combine
import SwiftUI
import Testing
@testable import IslandCore

private final class FakeModule: IslandModule {
    let id: String
    let priority: Int
    @Published var isActive: Bool
    var isActivePublisher: AnyPublisher<Bool, Never> { $isActive.eraseToAnyPublisher() }

    init(id: String, priority: Int, isActive: Bool) {
        self.id = id
        self.priority = priority
        self.isActive = isActive
    }

    func compactView() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
struct ModuleRegistryTests {
    @Test func activeModuleIsNilWhenNoModuleIsActive() {
        let modules = [
            FakeModule(id: "a", priority: 10, isActive: false),
            FakeModule(id: "b", priority: 5, isActive: false),
        ]
        let registry = ModuleRegistry(modules: modules)
        #expect(registry.activeModule == nil)
    }

    @Test func picksTheSingleActiveModule() {
        let modules = [
            FakeModule(id: "a", priority: 10, isActive: false),
            FakeModule(id: "b", priority: 5, isActive: true),
        ]
        let registry = ModuleRegistry(modules: modules)
        #expect(registry.activeModule?.id == "b")
    }

    @Test func picksHigherPriorityWhenMultipleModulesAreActive() {
        let modules = [
            FakeModule(id: "low", priority: 1, isActive: true),
            FakeModule(id: "high", priority: 100, isActive: true),
        ]
        let registry = ModuleRegistry(modules: modules)
        #expect(registry.activeModule?.id == "high")
    }

    @Test func firstInArrayWinsOnEqualPriorityTie() {
        let modules = [
            FakeModule(id: "first", priority: 5, isActive: true),
            FakeModule(id: "second", priority: 5, isActive: true),
        ]
        let registry = ModuleRegistry(modules: modules)
        #expect(registry.activeModule?.id == "first")
    }

    @Test func reactsWhenAModuleBecomesActiveAfterConstruction() async {
        let module = FakeModule(id: "a", priority: 1, isActive: false)
        let registry = ModuleRegistry(modules: [module])
        #expect(registry.activeModule == nil)

        module.isActive = true
        try? await Task.sleep(for: .milliseconds(10))

        #expect(registry.activeModule?.id == "a")
    }
}
