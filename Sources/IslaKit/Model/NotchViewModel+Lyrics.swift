import AppKit
import Combine
import UniformTypeIdentifiers

/// Turning lyrics on, importing them and the stage. Stored properties live in NotchViewModel.swift.
extension NotchViewModel {
    /// The stage: from the player's cover or title, ⌃⌥⌘L and the menu.
    /// Through `choose`, so a key pressed during the welcome answers it.
    func openStage() { choose(.stage) }

    /// Hide Lyrics: the stage turns back into the player.
    func hideLyrics() { open(.player) }

    /// Why the last lyric import or folder action did not work, said once,
    /// in the section that asked.
    ///
    /// Import LRC, Add Lyrics Folder and Rescan each dropped their error with
    /// `try?`, so a file Isla could not read closed the open panel and
    /// nothing happened at all (G-007). One notice, inline where the action
    /// was taken — under the lyrics page's header, or under Import LRC… in
    /// Settings — and never a second surface for the same failure: the panel
    /// has no toast, and one failure gets one place. The next lyric action
    /// or a track change takes it away.
    struct LyricsNotice: Equatable {
        enum Origin: Equatable {
            case stage
            case settings
        }

        let origin: Origin
        let text: String
    }

    /// Turns lyrics on from the lyrics page itself. The headline feature was
    /// off by default behind a switch in Settings, and the page only said so,
    /// so somebody who opened it to find words was sent somewhere else to get
    /// them. The switch stays the same one: this writes the key Settings reads.
    func turnOnLyrics() {
        UserDefaults.standard.set(true, forKey: Self.showLyricsKey)
        lyricsCoordinator.refreshVisibility()
    }

    /// Turns on the LRCLIB lookup from the page that just failed to find a
    /// local file, which is where a streamed song always ends up. The button
    /// carries the disclosure the Settings note does, so pressing it is the
    /// same informed choice as flipping the switch.
    func turnOnOnlineLyrics() {
        UserDefaults.standard.set(true, forKey: Self.onlineLyricsKey)
        lyricsCoordinator.refreshVisibility()
    }

    /// Import LRC, from the lyrics page (`.stage`) or from Settings
    /// (`.settings`), which is where a failure is said.
    ///
    /// The song is read before the open panel runs, because the panel is
    /// modal and a song can end while the listener browses: read after it
    /// returned, the file was bound to whichever song was playing then
    /// (G-013).
    func chooseLocalLyricsFile(from origin: LyricsNotice.Origin) {
        lyricsNotice = nil
        let identity = lyricsCoordinator.currentLocalTrackIdentity
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "lrc")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A main-actor turn later, not straight out of `runModal`: the picker
        // is still on screen until the run loop has had a pass to take it
        // down, and an import answered at once drew its confirmation (and any
        // refusal's notice) under a sheet that was about to vanish — the
        // island said "Lyrics imported" to nobody (MR-7, §10.4).
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.importLocalLyricsFile(at: url, for: identity, from: origin)
        }
    }

    /// The import itself, apart from the panel so it can be tested.
    func importLocalLyricsFile(at url: URL, for identity: LocalTrackIdentity?, from origin: LyricsNotice.Origin) {
        lyricsNotice = nil
        do {
            try lyricsCoordinator.importLocalFile(at: url, for: identity)
            confirm(.lyricsImported)
        } catch {
            report(Self.importFailure(error), from: origin)
        }
    }

    /// Puts the notice where it was asked for, and says it to VoiceOver: a
    /// line of caption text appearing under a header is easy to miss without
    /// sight, and the open panel that just closed took the focus with it.
    private func report(_ text: String, from origin: LyricsNotice.Origin) {
        lyricsNotice = LyricsNotice(origin: origin, text: text)
        Announcer.shared.announce(text)
    }

    /// What a refused file is told, in the listener's words: the line to
    /// look at when a stamp is broken, and plain text otherwise. The file's
    /// own name is not repeated — they picked it a moment ago.
    static func importFailure(_ error: Error) -> String {
        switch error as? LocalLyricsDocument.Error {
        case .invalidTimestamp(let line)?, .invalidWordOrder(let line)?:
            return localized("Line %d of this file has a time Isla can't read.", line)
        case .emptyTimeline?:
            return localized("This file has no timed lyrics.")
        case nil:
            // Not text in any encoding the library reads, or not readable at
            // all — a file gone, or one macOS will not let Isla open.
            return localized("Couldn't read this file as text.")
        }
    }

    func chooseLocalLyricsFolder() {
        lyricsNotice = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try localLyricsLibrary.addFolder(url)
        } catch {
            // The files inside a folder that was added are listed under its
            // row by the library; this is the folder itself failing.
            report(localized("Couldn't read: %@", url.lastPathComponent), from: .settings)
        }
    }

    func removeLocalLyricsFolder(_ url: URL) {
        lyricsNotice = nil
        localLyricsLibrary.removeFolder(url)
    }

    func rescanLocalLyrics() {
        lyricsNotice = nil
        do {
            try localLyricsLibrary.rescanFolders()
        } catch {
            let names = localLyricsLibrary.selectedFolders.map(\.lastPathComponent)
            report(localized("Couldn't read: %@", names.joined(separator: ", ")), from: .settings)
        }
    }

    func revealLocalLyricsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([localLyricsLibrary.storageDirectory])
    }

    func clearImportedLyrics() {
        stores.clearImportedLyrics()
    }

    func clearLyricsBindingsAndTimingCorrections() {
        stores.clearBindingsAndTimingCorrections()
    }

    func dismissUnassignedLyricsOffset(named filename: String) {
        lyrics.dismissUnassignedLegacyOffset(named: filename)
    }
}
