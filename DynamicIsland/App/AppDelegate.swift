import AppKit
import IslandCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var musicModule: MusicModule?
    private var registry: ModuleRegistry?
    private var panelController: IslandPanelController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let music = MusicModule()
        music.start()
        musicModule = music

        let registry = ModuleRegistry(modules: [music])
        self.registry = registry

        panelController = IslandPanelController(registry: registry)
        statusItemController = StatusItemController()
    }
}
