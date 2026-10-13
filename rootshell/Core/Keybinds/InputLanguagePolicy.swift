import Foundation

/// Pure decisions behind hardware input-source switching, shared by the
/// `textInputMode` override, the system input-mode observer and the cycle
/// action in `TerminalView+InputMode.swift`. Identifiers are opaque: UIKit
/// primary languages on iPad and visionOS, TIS source IDs on Mac Catalyst.
enum InputLanguagePolicy {
    /// Pseudo input modes UIKit reports while a transient UI (emoji search,
    /// dictation) owns the keyboard. They are never a language the user chose.
    static func isTransientLanguage(_ language: String?) -> Bool {
        language == "emoji" || language == "dictation"
    }

    /// The installed language a requested one lands on: an exact match first,
    /// else the first installed language the request prefixes, so a stored
    /// "zh-Hans" still reaches "zh-Hans-pinyin". Nil when nothing matches.
    static func resolve(_ target: String, among installed: [String]) -> String? {
        if installed.contains(target) { return target }
        return installed.first { $0.hasPrefix(target) }
    }

    /// Whether a system-side input-mode change should discard the stored
    /// preference. The system moving to a different real language means the
    /// user picked it with Globe or the keyboard's language list; keeping the
    /// override would snap the keyboard back on the next responder reload and
    /// leave every `textInputMode` reader describing a keyboard that is not up.
    /// Transient modes and an unknown system mode never discard it.
    static func shouldDropPreference(resolvedPreferred: String?, systemLanguage: String?) -> Bool {
        guard let systemLanguage, !isTransientLanguage(systemLanguage) else { return false }
        return systemLanguage != resolvedPreferred
    }

    /// The identifier after `current` in `ordered`, wrapping around. A nil or
    /// unknown current starts from the first entry. Nil when there are fewer
    /// than two sources, so there is nothing to cycle to.
    static func next(after current: String?, in ordered: [String]) -> String? {
        guard ordered.count > 1 else { return nil }
        let index = current.flatMap { ordered.firstIndex(of: $0) } ?? -1
        return ordered[(index + 1) % ordered.count]
    }
}
