import IslandCore
import SwiftUI

struct IslandShellView: View {
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject var viewModel: IslandShellViewModel

    var body: some View {
        Group {
            if let module = registry.activeModule {
                switch viewModel.state {
                case .collapsed:
                    Color.black
                case .compact:
                    module.compactView()
                case .expanded:
                    module.expandedView()
                }
            } else {
                Color.black
            }
        }
        .onHover { isHovering in
            if isHovering {
                viewModel.mouseEntered()
            } else {
                viewModel.mouseExited()
            }
        }
        .onTapGesture {
            viewModel.handleClick()
        }
    }
}
