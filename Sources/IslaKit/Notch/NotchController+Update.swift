import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import SwiftUI

/// The update alert. Stored properties live in NotchController.swift.
extension NotchController {
    // MARK: The update alert (spec §19.5 f)

    nonisolated static let updateOfferHoldDefault: TimeInterval = 20

    /// When an offer the island owes may show. Pure, so each reason is a
    /// test.
    enum UpdateOfferTiming: Equatable {
        case now
        /// Ask again after this long.
        case retry(TimeInterval)
        /// The displays are dark: the wake handler asks, and no timer runs
        /// all night for a screen nobody can see.
        case atWake
        /// The Mac is locked: the unlock asks.
        case atUnlock
    }

    /// Not under a pointer standing where the alert would grow — it would
    /// take the click meant for whatever is there — and not over a film, a
    /// talk or a game (K-003), as the charger and headphones are not. Unlike
    /// theirs, a refusal here is only a delay: the offer is owed until it is
    /// answered. The pointer moves on in a moment; a film or a talk runs for
    /// an hour, and once a minute is often enough to look.
    ///
    /// Nor on a locked Mac. With the lock card on, the island is marked locked
    /// and the queue already holds the offer; with the card off nothing is
    /// marked, the panel sinks under the shield, and an offer shown there
    /// folded unseen after its 20 s and was remembered as answered (review,
    /// 2026-10-19).
    nonisolated static func updateOfferTiming(
        pointerUnderAlert: Bool, screensAsleep: Bool, locked: Bool, quiet: Bool
    ) -> UpdateOfferTiming {
        if screensAsleep { return .atWake }
        if locked { return .atUnlock }
        if quiet { return .retry(60) }
        if pointerUnderAlert { return .retry(2) }
        return .now
    }

    /// The island is free, a check found something, or the installer moved
    /// on: offer what is owed, or take back an offer that is no longer owed.
    /// Every path that could show the alert comes through here, so the rule
    /// "once per version, at the first idle moment" lives in one place.
    func considerUpdateOffer() {
        guard let vm = viewModel else { return }
        let available = owedRelease()
        if let shown = vm.updateOffer {
            // Up already. While it is only an offer, a newer release takes its
            // place and a withdrawn one takes it down; once Install is
            // pressed it is the install's, whatever a check says.
            guard updateStage(for: shown).isTimed, available?.version != shown.version else { return }
            if let available {
                withAnimation(Theme.pill(reduceMotion: SystemAppearance.shared.reduceMotion)) {
                    vm.updateOffer = UpdateOffer(release: available)
                }
                Announcer.shared.announce(localized("Isla %@ is ready", available.version))
                scheduleUpdateFold(after: updateOfferHold)
            } else {
                foldUpdate()
            }
            return
        }
        guard let available else { return }
        presentUpdate(UpdateOffer(release: available))
    }

    /// Shows the offer through the queue, as every alert is shown: at once
    /// on an idle island, or waiting — past the second others get — behind a
    /// surface, the lock or a higher alert.
    func presentUpdate(_ offer: UpdateOffer) {
        guard let vm = viewModel, vm.updateOffer == nil else { return }
        // Asked again here, not only when it was posted: an offer that waited
        // behind the pop-up or an open panel may since have been answered,
        // withdrawn or overtaken, and shown for a frame before
        // `considerUpdateOffer` put it right it was a version announced that
        // was no longer offered (review, 2026-10-19).
        guard owedRelease()?.version == offer.version else { return }
        updateRetryWork?.cancel()
        updateRetryWork = nil
        let blocked = Self.alertsBlocked(
            isOpen: vm.isOpen, isDropTargeted: vm.isDropTargeted, isLocked: vm.isLockedPresentation
        )
        // The pointer is asked only once nothing blocks, as for the charger:
        // over an open panel it is always inside.
        if !blocked {
            let grown = NotchViewModel.updateBodySize(
                notchSize: vm.geometry.notchSize, bodyWidth: vm.geometry.expandedSize.width
            )
            let timing = Self.updateOfferTiming(
                pointerUnderAlert: pointer.isInside
                    || vm.geometry.grownAlertRect(for: .update(offer), body: grown).contains(pointerLocation()),
                screensAsleep: screensAreAsleep,
                locked: updateScreenUnseen,
                quiet: updateMomentsQuiet?() ?? momentsAreQuiet()
            )
            switch timing {
            case .now: break
            case .retry(let delay):
                scheduleUpdateRetry(after: delay)
                return
            case .atWake, .atUnlock:
                return
            }
        }
        guard postAlert(.update(offer), to: vm) == .show else { return }

        peekWork?.cancel()
        peekWork = nil
        withAnimation(Theme.pill(reduceMotion: SystemAppearance.shared.reduceMotion)) {
            vm.isPeeking = false
            vm.updateOffer = offer
        }
        // After every refusal, as for the other alerts: a sentence for an
        // alert nobody can see would be the voice lying.
        Announcer.shared.announce(localized("Isla %@ is ready", offer.version))
        scheduleUpdateFold(after: updateOfferHold)
    }

    /// Nobody can see the island: locked, behind the screen saver, or with
    /// another user switched in. An offer waits through all three, for the
    /// same reason — folded unseen, it would count as answered.
    private var updateScreenUnseen: Bool {
        (updateScreenLocked?() ?? lockPresence.isLocked) || screenSaverRunning || !sessionActive
    }

    /// The screen saver started or stopped.
    func screenSaverChanged(running: Bool) {
        guard screenSaverRunning != running else { return }
        screenSaverRunning = running
        running ? clearUpdateOffer() : updateScreenSeenAgain()
    }

    /// Another user was switched in, or this one came back.
    func sessionActiveChanged(_ active: Bool) {
        guard sessionActive != active else { return }
        sessionActive = active
        active ? updateScreenSeenAgain() : clearUpdateOffer()
    }

    /// The screen is seen again — an unlock, the screen saver's end, the
    /// session back: what was held back is owed. On the next pass, once
    /// whatever the moment changed on screen has landed, and through
    /// `presentUpdate`'s own rules, so a display still dark or a lock still
    /// standing keeps it waiting.
    func updateScreenSeenAgain() {
        DispatchQueue.main.async { [weak self] in self?.considerUpdateOffer() }
    }

    /// What the island owes an alert for. While an install runs, the release
    /// being installed: its alert follows it to the end, whatever a check has
    /// found since — a newer build that landed meanwhile came back, after a
    /// pop-up took the alert's place, titled over the older one's progress
    /// (Codex review, 2026-10-19). Otherwise the newest release not yet
    /// answered.
    private func owedRelease() -> UpdateCheck.Release? {
        let state = installerState()
        if state.phase.isBusy, let installing = state.release { return installing }
        return availableUpdate().flatMap { updateOfferMemory.isUnanswered($0.version) ? $0 : nil }
    }

    /// The stage the alert shows for `offer`, by where the installer is.
    func updateStage(for offer: UpdateOffer) -> UpdateAlertStage {
        let state = installerState()
        return UpdateAlertStage.make(phase: state.phase, installerRelease: state.release, offer: offer)
    }

    /// Folds an unanswered offer after `delay` and remembers it was offered;
    /// with the pointer resting on it, asks again a second later
    /// (`ambientRecheck`), so it never folds under someone reading it. An
    /// offer that has become an install is not timed, and the alert stays.
    private func scheduleUpdateFold(after delay: TimeInterval) {
        updateFoldWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let vm = self.viewModel, let offer = vm.updateOffer else { return }
            self.updateFoldWork = nil
            guard self.updateStage(for: offer).isTimed else { return }
            if let wait = Self.ambientRecheck(pointerInside: self.pointer.isInside) {
                self.scheduleUpdateFold(after: wait)
                return
            }
            self.answerUpdate(offer)
        }
        updateFoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleUpdateRetry(after delay: TimeInterval) {
        updateRetryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateRetryWork = nil
            self?.considerUpdateOffer()
        }
        updateRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The installer's step, with the download's progress taken out: the
    /// controller acts on a step changing, and a download reports its bytes
    /// many times a second — the alert's own view draws those.
    nonisolated static func updateStep(_ phase: UpdateInstaller.Phase) -> UpdateInstaller.Phase {
        if case .downloading = phase { return .downloading(received: 0, total: 0) }
        return phase
    }

    /// A check or the installer moved. An offer up and back to being only an
    /// offer — an install reset from Settings — is timed again.
    func updateStateChanged() {
        considerUpdateOffer()
        guard let vm = viewModel, let offer = vm.updateOffer, updateFoldWork == nil,
              updateStage(for: offer).isTimed else { return }
        scheduleUpdateFold(after: updateOfferHold)
    }

    /// A button on the alert (spec §19.5 f, and plan 2026-10-19 for the
    /// stages after Install).
    func updateAlertAction(_ action: UpdateAlertAction) {
        guard let vm = viewModel, let offer = vm.updateOffer else { return }
        switch action {
        case .later:
            answerUpdate(offer)
        case .install, .tryAgain:
            // Not an answer yet: an install that ends with the Mac restarting
            // midway, or a failure left standing, is offered again. The alert
            // stays, untimed, and follows the install.
            updateFoldWork?.cancel()
            updateFoldWork = nil
            installUpdate(offer.release, action == .tryAgain)
        case .settings:
            // An update this copy cannot install for itself: the card in
            // Settings has its download page.
            answerUpdate(offer)
            islandClicked(opening: .settings)
        case .quit:
            updateOfferMemory.remember(offer.version)
            quitApp()
        }
    }

    /// Later, or the hold running out: the version is remembered, and the
    /// gear keeps its badge (§19.5 f).
    private func answerUpdate(_ offer: UpdateOffer) {
        updateOfferMemory.remember(offer.version)
        foldUpdate()
    }

    /// The alert folds, and the island returns to what is live or to an
    /// alert still waiting.
    private func foldUpdate() {
        guard let vm = viewModel else { return }
        cancelUpdateWork()
        withAnimation(Theme.pill(reduceMotion: SystemAppearance.shared.reduceMotion)) {
            vm.updateOffer = nil
        }
        promoteWaitingAlert()
    }

    /// Takes the alert down unanswered, for a lock, a dark display and a
    /// quiet Space: it is offered again when the island is free.
    func clearUpdateOffer() {
        cancelUpdateWork()
        viewModel?.updateOffer = nil
    }

    func cancelUpdateWork() {
        updateFoldWork?.cancel()
        updateFoldWork = nil
        updateRetryWork?.cancel()
        updateRetryWork = nil
    }
}
