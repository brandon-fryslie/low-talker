import Flavors
import Foundation

/// The app's guided setup: the onboarding list walked one requirement at a time, each one
/// explained before macOS is asked for anything.
///
/// [LAW:one-source-of-truth] A view of `Readiness` and nothing more. Which steps there are,
/// and whether each is done, is read off the list every time; the walk remembers only which
/// steps the person chose to skip, which is the one thing the list cannot know.
public struct GuidedSetup: Sendable, Equatable {
    /// The steps the person set aside in this walk. Kept only while the walk is open: a
    /// skipped step is offered again the next time setup opens.
    public private(set) var skipped: Set<Requirement.Row> = []

    public init() {}

    /// What the menu item and every step that points at the setup call it.
    public static func title(for flavor: Flavor) -> String {
        "Set Up \(flavor.displayName)…"
    }

    /// The step to show: the first requirement with something left to do that the person
    /// has not set aside, or nil when there is none and the walk shows where things stand.
    public func current(in readiness: Readiness) -> Requirement? {
        readiness.unmet.first { !skipped.contains($0.row) }
    }

    /// Sets a step aside, so the walk moves on without it. Declining is not an error: the
    /// app keeps running, and the step waits in the summary with what skipping it costs.
    public mutating func skip(_ row: Requirement.Row) {
        skipped.insert(row)
    }

    /// Brings a skipped step back, which is how the summary resumes the walk at it.
    public mutating func revisit(_ row: Requirement.Row) {
        skipped.remove(row)
    }
}

/// Why a requirement is asked for, in the words a person reads before macOS asks them
/// anything: what it is for, and what happens without it. One sentence each, at most two.
public struct Explanation: Sendable, Hashable {
    public let why: String
    public let ifSkipped: String
}

public extension Requirement.Row {
    /// This step's explanation, naming the installation it is shown in.
    ///
    /// [LAW:types-are-the-program] An exhaustive switch, so a row added to the list cannot
    /// compile without the answers a person needs before being asked for it.
    func explanation(for flavor: Flavor) -> Explanation {
        let app = flavor.displayName
        let otherHotkey = "The hotkey stays off. The other hotkey, under Hotkey source in the menu, needs no permission."
        let otherDelivery = "\(app) can't type. Input Method, under Delivery in the menu, needs no driver."
        return switch self {
        case .microphone:
            Explanation(
                why: "\(app) listens only while you hold your dictation key. Audio stays on this Mac.",
                ifSkipped: "\(app) can't hear you.")
        case .accessibility:
            Explanation(
                why: "Stops your dictation key from also reaching the app you're typing in.",
                ifSkipped: otherHotkey)
        case .inputMonitoring:
            Explanation(
                why: "Lets \(app) notice your dictation key. Every other key is ignored.",
                ifSkipped: otherHotkey)
        case .inputMethod:
            Explanation(
                why: "Puts your words at the cursor in any app.",
                ifSkipped: "Your words can't reach the cursor. Virtual Keyboard, under Delivery in the menu, is the other way.")
        case .driverExtension:
            Explanation(
                why: "The virtual keyboard needs a driver. Installing it takes an administrator password, then an approval in System Settings.",
                ifSkipped: otherDelivery)
        case .keyboardHelper:
            Explanation(
                why: "A background helper drives the virtual keyboard. macOS keeps it off until you allow it.",
                ifSkipped: otherDelivery)
        case .keyboardSetupAssistant:
            Explanation(
                why: "\(app)'s helper answers the macOS keyboard setup window, so it doesn't take your first dictation.",
                ifSkipped: "Nothing to do. This clears once the helper runs.")
        }
    }

    /// The button that asks macOS, named for what it asks, or nil for a row the app cannot
    /// ask for: the driver is installed by an administrator, and the assistant's answer is
    /// filed by the helper. The ellipsis says a dialog follows.
    var askTitle: String? {
        switch self {
        case .microphone: "Allow Microphone…"
        case .inputMonitoring: "Allow Input Monitoring…"
        case .accessibility: "Allow Accessibility…"
        case .inputMethod: "Switch On Input Method…"
        case .keyboardHelper: "Allow Keyboard Helper…"
        case .driverExtension, .keyboardSetupAssistant: nil
        }
    }

    /// The System Settings pane where this grant is switched by hand, which is where a
    /// person goes after declining macOS's dialog: most of these dialogs are shown once.
    var settingsPane: URL? {
        let privacy = "x-apple.systempreferences:com.apple.preference.security?"
        return switch self {
        case .microphone: URL(string: privacy + "Privacy_Microphone")
        case .inputMonitoring: URL(string: privacy + "Privacy_ListenEvent")
        case .accessibility: URL(string: privacy + "Privacy_Accessibility")
        case .inputMethod: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        case .driverExtension, .keyboardHelper: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        case .keyboardSetupAssistant: nil
        }
    }
}
