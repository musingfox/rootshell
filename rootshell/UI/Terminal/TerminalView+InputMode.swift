//
//  TerminalView+InputMode.swift
//  rootshell
//
//  Overrides `textInputMode` so a preferred primary language nudges the
//  hardware-keyboard input source. The switch is realized by briefly
//  handing first-responder to a parked text field and then taking it back,
//  which is the standard iOS pattern for refreshing the active input mode
//  without dismissing the keyboard window.
//

import UIKit
import os

extension Ghostty.TerminalView {

    override var textInputMode: UITextInputMode? {
        // Emoji search is owned by UIKit even when the terminal remains the
        // text-input responder. A saved language must not mask that mode.
        if isSystemEmojiInputActive { return super.textInputMode }
        guard let target = preferredInputLanguage,
              let mode = resolvedInputMode(forPrimaryLanguage: target) else { return super.textInputMode }
        return mode
    }

    /// The installed input mode a preferred language lands on: an exact
    /// primary-language match first, else the first mode the request prefixes.
    func resolvedInputMode(forPrimaryLanguage target: String) -> UITextInputMode? {
        let modes = UITextInputMode.activeInputModes
        guard let language = InputLanguagePolicy.resolve(target, among: modes.compactMap(\.primaryLanguage)) else {
            return nil
        }
        return modes.first { $0.primaryLanguage == language }
    }

    /// The input mode UIKit actually has up, bypassing the preferred-language
    /// override. The override is a request; this is what the keyboard shows.
    var systemInputPrimaryLanguage: String? {
        super.textInputMode?.primaryLanguage
    }

    /// Read the system mode, not our preferred-language override. Hardware
    /// search keys belong to the emoji keyboard; only its committed text
    /// should reach insertText and the terminal session.
    var isSystemEmojiInputActive: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return super.textInputMode?.primaryLanguage == "emoji"
        #endif
    }

    /// iPad's hardware emoji popover keeps the terminal as first responder and
    /// reports the normal language (for example en-US), even during search.
    /// Yield only while its search field is visible. This compatibility check
    /// uses an observed UIKit class name; recheck it when updating iPadOS.
    var shouldYieldHardwareInputToEmojiUI: Bool {
        if isSystemEmojiInputActive { return true }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard isFirstResponder, let hostWindow = window,
              let scene = hostWindow.windowScene,
              scene.activationState == .foregroundActive else { return false }

        func containsVisibleEmojiSearch(_ view: UIView) -> Bool {
            guard !view.isHidden, view.alpha > 0 else { return false }
            if NSStringFromClass(type(of: view)) == "TUIEmojiSearchTextField" {
                return !view.bounds.isEmpty
            }
            return view.subviews.contains(where: containsVisibleEmojiSearch)
        }

        var windows = scene.windows
        // Hardware emoji search can live in a remote keyboard window with its
        // own system scene. Include tracked keyboard windows for the key host,
        // as well as the accessory's window when one is installed.
        for candidate in SystemShiftReader.shared.keyboardWindows(for: hostWindow, near: keyboardAccessory)
            where !windows.contains(where: { $0 === candidate }) {
            windows.append(candidate)
        }
        return windows.contains { candidate in
            candidate !== hostWindow
                && candidate.windowLevel > hostWindow.windowLevel
                && containsVisibleEmojiSearch(candidate)
        }
        #else
        return false
        #endif
    }

    /// Switch the hardware-keyboard input source for this terminal.
    ///
    /// iPad / visionOS: set `preferredInputLanguage` and refresh the responder
    /// via a parked text field so the keyboard accessory bar and candidate
    /// strip aren't torn down by a bare `resignFirstResponder()`.
    /// Mac Catalyst: dispatch via Carbon TIS — the UIKit textInputMode override
    /// is not honored by AppKit's input-source machinery on Catalyst.
    func applyInputLanguageSwitch(toPrimaryLanguage target: String) {
        // Resolve the outgoing input method before the system swaps it out,
        // in the order prepareTouchKeyboardSwitch() uses. A half-composed
        // Hangul syllable in the local model, or UIKit marked text, would
        // otherwise stay on screen as stale preedit (or be dropped) under the
        // new keyboard. On Catalyst the macOS input method commits or discards
        // its own marked text when it is deactivated; only the local model
        // needs flushing there.
        commitKoreanCompositionIfNeeded(external: true)
        #if !targetEnvironment(macCatalyst)
        if markedTextString != nil { unmarkText() }
        #endif
        endDictationSession()
        invalidateWritingAssistance()
        #if targetEnvironment(macCatalyst)
        // Catalyst's TIS call triggers the native macOS input-source HUD,
        // so no in-app overlay is needed here.
        InputSourceCatalog.catalystSwitch(toPrimaryLanguage: target)
        #else
        guard let resolved = resolvedInputMode(forPrimaryLanguage: target)?.primaryLanguage else {
            // Nothing installed can honor the request; a stored preference
            // would only make textInputMode readers lie about the keyboard.
            Ghostty.logger.warning("Input-source switch: no installed keyboard matches \(target, privacy: .public)")
            return
        }
        // This preference (and our textInputMode override) reflects a request,
        // not the source UIKit selected through Globe or its language picker.
        // Reapply explicit requests even when the stored preference matches.
        preferredInputLanguage = target
        showInputModeOverlay(displayName(forPrimaryLanguage: resolved))

        // The system already shows the resolved mode (a mod-tap aimed at the
        // active language): the responder round-trip below would only rebuild
        // the input views and flicker focus for no change.
        guard systemInputPrimaryLanguage != resolved else { return }

        // If we're not currently first responder, the override applies next time
        // we become first responder — nothing else to do.
        guard isFirstResponder else { return }

        let parking = ensureSwapParkingField()
        // Order: park grabs first responder, then we take it back on the next
        // runloop turn so UIKit has actually surfaced the override. The flag
        // tells resign/become to leave the touch keyboard, its modifiers and
        // Ghostty focus alone: focus is only parked, not lost.
        isSwappingResponderForInputLanguage = true
        guard parking.becomeFirstResponder() else {
            // Our resignFirstResponder() refused (app transition, secure draw).
            // The override still applies on the next genuine focus change.
            isSwappingResponderForInputLanguage = false
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.isSwappingResponderForInputLanguage = false }
            guard !self.becomeFirstResponder() else { return }
            // Never leave the keyboard parked on a hidden field: give up the
            // park and run the focus-loss cleanup resignFirstResponder() skipped.
            _ = parking.resignFirstResponder()
            self.abandonInputLanguageSwap()
        }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    /// Resolve a friendly name for the overlay. Prefer the active input mode's
    /// localized identifier (so a system-installed mode picks up its full name)
    /// and fall back to a plain locale-string lookup on the language code.
    private func displayName(forPrimaryLanguage lang: String) -> String {
        if let mode = UITextInputMode.activeInputModes.first(where: { $0.primaryLanguage == lang }),
           let primary = mode.primaryLanguage,
           let localized = Locale.current.localizedString(forIdentifier: primary) {
            return localized
        }
        return Locale.current.localizedString(forIdentifier: lang) ?? lang
    }
    #endif

    /// Advance the hardware-keyboard input source to the next installed one,
    /// wrapping around — the in-app analogue of the system Ctrl+Space input
    /// cycle. The live input-source set and the current source are both re-read
    /// on every call (no cross-invocation state), so a keyboard added/removed
    /// while the app is running is reflected on the very next press.
    func cycleInputSource() {
        let sources = InputSourceCatalog.available()
        guard let next = InputLanguagePolicy.next(
            after: currentInputSourceIdentifier(),
            in: sources.map(\.primaryLanguage)
        ) else {
            // 0 or 1 installed source: nothing to cycle.
            #if !targetEnvironment(macCatalyst)
            if let only = sources.first {
                showInputModeOverlay(only.displayName)
            }
            #endif
            return
        }
        applyInputLanguageSwitch(toPrimaryLanguage: next)
    }

    /// The currently-effective input source identifier, in the same namespace as
    /// `InputSourceCatalog.available()` (UITextInputMode primaryLanguage on
    /// iPad/visionOS, raw TIS source ID on Mac Catalyst).
    private func currentInputSourceIdentifier() -> String? {
        #if targetEnvironment(macCatalyst)
        return InputSourceCatalog.currentSourceID()
        #else
        // textInputMode reflects our preferredInputLanguage override when set,
        // else the system's active mode — both are the correct "current" to
        // advance from.
        return textInputMode?.primaryLanguage
        #endif
    }

    /// Drop the preferred-language override so a subsequent system input-source
    /// cycle (e.g. user-pressed Ctrl+Space) is not snapped back by our override.
    /// Called from the existing Ctrl+Space pass-through paths in pressesBegan
    /// / processKeyPress so the system HUD behaves normally.
    func yieldInputLanguageOverrideForSystemCycle() {
        preferredInputLanguage = nil
    }

    private func ensureSwapParkingField() -> UITextField {
        if let existing = inputLanguageSwapParkingField {
            return existing
        }
        let field = UITextField(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
        field.isHidden = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        // Adding to self keeps the field in the responder chain even if our
        // superview changes (split panes, tab swaps).
        addSubview(field)
        inputLanguageSwapParkingField = field
        return field
    }
}
