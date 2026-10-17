import Foundation

/// UI language. Same source of truth as Localizable.strings, so names and labels never disagree.
enum L10n {
    /// English only inside the app bundle (it ships ko and en); a bare binary or test runner reports "en" but has
    /// no strings table, so its labels stay Korean and so do the names.
    static let english: Bool =
        Bundle.main.localizations.contains("ko") && Bundle.main.preferredLocalizations.first == "en"
}
