import Foundation

/// Where Update Now takes its releases from.
///
/// GitHub, for everyone. Two local folders stand in for it, and both are read
/// through the same rules the rehearsal introduced (`UpdateCheck.trustedAsset`,
/// `UpdateCheck.isRehearsalFile`): a `release.json` shaped like GitHub's answer,
/// and `file://` assets that must be that folder's own files. What may be
/// *installed* does not change with the source — the Ed25519 signature against
/// the key in the app, the validator, the atomic swap and the relaunch are the
/// ones a GitHub release goes through.
///
/// - **A rehearsal** (`DI_UPDATE_REHEARSAL`, read by `DebugTrail`): one launch's
///   worth, by hand, to try an update on a real Mac (`Scripts/rehearse-update.sh`).
/// - **The local feed** (the `updates.localFeed` setting): the owner's own Mac,
///   following every change as it is made. The owner asked on 2026-10-19 that
///   new work reach the running app through Isla's own update rather than a
///   reinstall each time; `Scripts/publish-dev-update.sh` signs each build into
///   the folder, and the island offers it (plan 2026-10-19).
///
/// The setting grants nothing a process could not already take: whoever can
/// write Isla's defaults runs as the user who owns `/Applications/Isla.app`,
/// and could replace the app itself. What the folder rule adds is that no
/// *other* account can fill the feed — it must be the user's own directory,
/// writable by nobody else — so the feed is only ever what the user put there,
/// and the signature still decides whether any of it installs.
enum UpdateSource: Equatable, Sendable {
    case github
    case rehearsal(URL)
    case localFeed(URL)

    /// The folder releases are read from, or nil for GitHub.
    var folder: URL? {
        switch self {
        case .github: return nil
        case .rehearsal(let folder), .localFeed(let folder): return folder
        }
    }

    /// The setting that turns the local feed on: an absolute path. Spelled in
    /// this file and nowhere else; everything else asks `current`.
    static let localFeedKey = "updates.localFeed"

    /// This run's source, decided once, at first use: the rehearsal variable,
    /// else the setting, else GitHub. Like the variable, the setting is read
    /// once — a feed turned on or off takes effect at the next launch, which an
    /// update's own relaunch is.
    static let current: UpdateSource = {
        let setting = UserDefaults.standard.string(forKey: localFeedKey)
        let source = resolve(rehearsal: DebugTrail.updateRehearsal, setting: setting)
        if let setting, !setting.isEmpty, case .github = source, DebugTrail.updateRehearsal == nil {
            Log.updates.error("updates.localFeed is not a folder only this user can write, so updates come from GitHub")
        }
        return source
    }()

    /// Which source a launch with these inputs follows. Pure apart from the
    /// file system, and the owner is asked through `owner` so a test can play
    /// another account.
    nonisolated static func resolve(
        rehearsal: URL?, setting: String?,
        owner: (URL) -> UInt32? = UpdateInstaller.ownerID, user: UInt32 = getuid()
    ) -> UpdateSource {
        if let rehearsal { return .rehearsal(rehearsal) }
        if let feed = localFeedFolder(setting, owner: owner, user: user) { return .localFeed(feed) }
        return .github
    }

    /// The setting's folder, links resolved, when it is one the local feed may
    /// be: an absolute path to a directory the current user owns and nobody
    /// else may write (no group or other write bit — a sticky world-writable
    /// folder is still everybody's to fill), inside folders nobody else could
    /// rename it out of. Anything else is nil.
    nonisolated static func localFeedFolder(
        _ setting: String?, owner: (URL) -> UInt32? = UpdateInstaller.ownerID, user: UInt32 = getuid()
    ) -> URL? {
        guard let setting, setting.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: setting, isDirectory: true).resolvingSymlinksInPath()
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        guard owner(url) == user else { return nil }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return nil }
        guard ancestorsHold(url, user: user) else { return nil }
        return url
    }

    /// Whether every folder above `url` is root's or `user`'s, and writable by
    /// others only when sticky. A feed of the user's own inside a folder
    /// others can write could be renamed away and a folder of theirs put in
    /// its place (review, 2026-10-19); the sticky bit is what keeps that from
    /// happening in /tmp. Followed with `stat`, not `lstat`: Foundation spells
    /// a resolved path under /private as /var or /tmp, which are links to it.
    nonisolated private static func ancestorsHold(_ url: URL, user: UInt32) -> Bool {
        var folder = url.deletingLastPathComponent()
        while true {
            var info = stat()
            guard stat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == 0 || info.st_uid == user
            else { return false }
            if info.st_mode & (S_IWGRP | S_IWOTH) != 0, info.st_mode & S_ISVTX == 0 { return false }
            if folder.path == "/" { return true }
            folder = folder.deletingLastPathComponent()
        }
    }

    /// Whether this source may still be read. GitHub and a rehearsal, always.
    /// The local feed is judged at launch and again before every read — by
    /// the check and by the download — so a folder that has since become
    /// writable by others, or been swapped for a link elsewhere, is read no
    /// more; the signature would refuse what was put there, but a feed nobody
    /// else can fill is the rule, not the hope.
    nonisolated func stillHolds(owner: (URL) -> UInt32? = UpdateInstaller.ownerID, user: UInt32 = getuid()) -> Bool {
        guard case .localFeed(let folder) = self else { return true }
        return Self.localFeedFolder(folder.path, owner: owner, user: user) == folder
    }
}
