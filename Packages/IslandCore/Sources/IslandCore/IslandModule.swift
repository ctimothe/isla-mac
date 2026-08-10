import Combine
import SwiftUI

@MainActor
public protocol IslandModule: AnyObject {
    var id: String { get }
    var priority: Int { get }
    var isActive: Bool { get }
    var isActivePublisher: AnyPublisher<Bool, Never> { get }
    func compactView() -> AnyView
    func expandedView() -> AnyView
}
