import Foundation

/// Every symbol the Settings pane draws, named once.
///
/// Gathered so the set can be judged as a set — an icon that means the wrong
/// thing is mostly visible next to its neighbours — and so a test can prove each
/// name still resolves. An unresolvable name draws nothing at all, which reads
/// as a broken build rather than as the typo it is.
///
/// The rule for choosing one: name the action, not the mood. A row that saves
/// gets the platform's save glyph; a row that connects an account gets a person;
/// a row that shows a brief preview gets an eye. Decorative symbols — `sparkles`
/// above all — say "something happens here" and nothing else.
enum SettingsIcon {
    /// The island's moments without music: what each one shows.
    static let showCharging = "bolt"
    static let showHeadphones = "headphones"
    /// Dismissing a leftover timing correction sets it aside; it deletes no file.
    static let dismiss = "xmark.circle"
    /// A switch that reaches the network. The globe is kept for those and only
    /// those — lyrics looked up online, text translated online — so the rows
    /// that can send something off this Mac say so at a glance.
    static let online = "globe"
    /// Examining the app's state, which is what the report is.
    static let copyDiagnostics = "stethoscope"
    static let reportProblem = "exclamationmark.bubble"

    static let all: [String] = [showCharging, showHeadphones, dismiss, online, copyDiagnostics, reportProblem]
}
