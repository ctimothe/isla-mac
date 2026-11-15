import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import SwiftUI

/// Live activities on the island. Stored properties live in NotchController.swift.
extension NotchController {
    // MARK: - Live activities (plan 2026-11-14)

    func liveActivitiesChanged(_ live: [LiveActivity]) {
        guard let vm = viewModel else { return }
        let before = (vm.activity, vm.bubble, vm.bodySize)
        vm.liveActivities = live
        // A live activity arriving or leaving moves the island and the
        // bubble: cut the clickable regions again, as the Shelf's first and
        // last file do. A timer ticking changes neither.
        if before != (vm.activity, vm.bubble, vm.bodySize) { refreshCollapsedRects() }
        // Controls whose timer has gone (cancelled, finished, reset) go too.
        if let kind = vm.expandedLive, !live.contains(where: { $0.kind == kind }) { foldTimerControls() }
    }

    /// The bubble does what a click on its activity would: the Shelf's opens
    /// the tray, the song's the player, a timer's its controls.
    func bubbleClicked() {
        guard let vm = viewModel, let bubble = vm.bubble else { return }
        switch bubble {
        case .shelf: islandClicked(opening: .tray)
        case .music, .peek: islandClicked(opening: .player)
        case .live(let live): liveClicked(live)
        default: islandClicked()
        }
    }

    func liveClicked(_ live: LiveActivity) {
        if live.hasControls {
            // A timer's Pause and Cancel, the microphone's Mute and Quit: a
            // card in place, as the iPhone's long-press opens one. From the
            // bubble it takes the island until it folds (`IslandActivity.current`).
            guard let vm = viewModel else { return }
            if vm.expandedLive == live.kind {
                foldTimerControls()
            } else {
                withAnimation(Theme.island(reduceMotion: SystemAppearance.shared.reduceMotion)) {
                    vm.expandedLive = live.kind
                }
                refreshCollapsedRects()
                scheduleTimerControlsFold()
            }
            return
        }
        switch live {
        case .timer, .stopwatch:
            break
        case .recording:
            // A camera alone names no app and has nothing to mute; its click
            // opens the panel, as the island's does (`NotchViewModel.click`).
            islandClicked(opening: viewModel?.openTarget)
        case .downloads:
            if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                NSWorkspace.shared.open(folder)
            }
        }
    }

    /// The controls fold on their own 6 s after they opened or were last
    /// pressed, as an alert's hold does; a press restarts the wait.
    private func scheduleTimerControlsFold() {
        timerControlsFold?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.foldTimerControls() }
        timerControlsFold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timerControlsHold, execute: work)
    }

    static let timerControlsHold: TimeInterval = 6

    private func foldTimerControls() {
        timerControlsFold?.cancel()
        timerControlsFold = nil
        guard let vm = viewModel, vm.expandedLive != nil else { return }
        withAnimation(Theme.island(reduceMotion: SystemAppearance.shared.reduceMotion)) { vm.expandedLive = nil }
        refreshCollapsedRects()
    }

    func timerControl(_ control: TimerControl) {
        guard let vm = viewModel, let kind = vm.expandedLive else { return }
        let timers = stores.live.timers
        switch (kind, control) {
        case ("timer", .pause): timers.pauseCountdown()
        case ("timer", .resume): timers.resumeCountdown()
        case ("timer", .cancel), ("timer", .reset): timers.cancelCountdown()
        case ("stopwatch", .pause): timers.pauseStopwatch()
        case ("stopwatch", .resume): timers.resumeStopwatch()
        case ("stopwatch", .reset), ("stopwatch", .cancel): timers.resetStopwatch()
        default: break
        }
        scheduleTimerControlsFold()
    }

    func microphoneControl(_ control: MicrophoneControl) {
        guard let vm = viewModel, case .live(.recording(let state)) = vm.activity else { return }
        switch control {
        case .mute: stores.live.setMicrophoneMuted(true)
        case .unmute: stores.live.setMicrophoneMuted(false)
        case .show(let app):
            NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.activate()
            foldTimerControls()
            return
        case .quit:
            // Which app, chosen from a menu naming each: the row is the
            // confirmation. `terminate` is the app's own Quit, so one with
            // unsaved work asks about it as ⌘Q would.
            var seen = Set<String>()
            let apps = state.microphoneApps.map(LiveActivityHub.owningApp(of:)).filter { seen.insert($0).inserted }
            let rows: [(title: String, run: () -> Void)] = apps.map { app in
                let name = MicrophoneControlsView.name(of: app)
                return (localized("Quit %@", name), { [weak self] in
                    NSRunningApplication.runningApplications(withBundleIdentifier: app).forEach { $0.terminate() }
                    self?.foldTimerControls()
                })
            }
            guard !rows.isEmpty, let rootView, let window = rootView.window else { return }
            // The card stays while the menu tracks, so the choice has a card
            // to come back to; the hold starts again below once it closes.
            timerControlsFold?.cancel()
            let point = rootView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            IslandMenu.choices(rows).popUp(positioning: nil, at: point, in: rootView)
        }
        scheduleTimerControlsFold()
    }

    func timerFinished(_ duration: TimeInterval) {
        foldTimerControls()
        // Heard whether or not the island can draw the alert: a timer that
        // ends behind a full-screen film still rang.
        NSSound(named: "Glass")?.play()
        presentAmbient(.timerDone(duration: duration))
    }

    /// Selects a file in ~/Downloads in Finder. A file already moved or
    /// deleted opens the folder instead, rather than nothing.
    static func revealDownload(named name: String) {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let file = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    func downloadEvent(_ event: DownloadEvent) {
        switch event {
        case .finished(let url): viewModel?.confirm(.downloaded(name: url.lastPathComponent))
        case .airDropReceived(let url): viewModel?.confirm(.airDropped(name: url.lastPathComponent))
        }
    }
}
