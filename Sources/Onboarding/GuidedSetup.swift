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
/// anything: why, what it lets them do, and what still works if they say no.
public struct Explanation: Sendable, Hashable {
    public let why: String
    public let enables: String
    public let ifSkipped: String
}

public extension Requirement.Row {
    /// This step's explanation, naming the installation it is shown in.
    ///
    /// [LAW:types-are-the-program] An exhaustive switch, so a row added to the list cannot
    /// compile without the three answers a person needs before being asked for it.
    func explanation(for flavor: Flavor) -> Explanation {
        let app = flavor.displayName
        let otherHotkey = """
            That hotkey stays off. You can still dictate: choose the other hotkey under \
            Hotkey source in the menu. macOS hands that one to \(app) directly, and it needs \
            no permission.
            """
        let otherDeliveryThanTheVirtualKeyboard = """
            The virtual keyboard can't type. You can choose Input Method under Delivery in \
            the menu instead; it needs no driver and no helper.
            """
        return switch self {
        case .microphone:
            Explanation(
                why: """
                    \(app) turns what you say into text, so it has to hear you. It listens \
                    only while you hold or tap your dictation key, and what it hears never \
                    leaves this Mac.
                    """,
                enables: "Dictation: you speak, and your words appear where you are typing.",
                ifSkipped: """
                    Nothing can be dictated. \(app) stays in the menu bar, and you can come \
                    back to this step from \(GuidedSetup.title(for: flavor)) at any time.
                    """)
        case .inputMonitoring:
            Explanation(
                why: """
                    Your dictation key is one you already have, like Right Option. To notice \
                    you pressing it, \(app) has to watch the keyboard. It looks for that one \
                    key and ignores the rest: nothing you type is kept or sent anywhere.
                    """,
                enables: "Starting dictation with a modifier key on its own.",
                ifSkipped: otherHotkey)
        case .accessibility:
            Explanation(
                why: """
                    When you press your dictation key, \(app) stops that key press from also \
                    reaching the app you are typing in, so the app does not react to it. \
                    macOS counts that as controlling your computer, which is why it asks.
                    """,
                enables: "Dictating into any app without the hotkey leaking into it.",
                ifSkipped: otherHotkey)
        case .inputMethod:
            Explanation(
                why: """
                    \(app) puts your words at your cursor through its own input method, the \
                    same kind of add-on macOS uses for typing in other languages. macOS asks \
                    you before any app switches one on.
                    """,
                enables: "Your words appear at the cursor in whatever app you are using.",
                ifSkipped: """
                    Your words cannot reach the cursor. You can choose Virtual Keyboard \
                    under Delivery in the menu instead.
                    """)
        case .driverExtension:
            Explanation(
                why: """
                    The virtual keyboard types your words the way a real keyboard would, and \
                    macOS needs a small driver for that. Installing it takes an \
                    administrator's password, and then macOS asks you to approve it in \
                    System Settings.
                    """,
                enables: "Typing your words into any app, including ones that do not work with input methods.",
                ifSkipped: otherDeliveryThanTheVirtualKeyboard)
        case .keyboardHelper:
            Explanation(
                why: """
                    A small helper runs in the background to drive the virtual keyboard. \
                    macOS lists it in Login Items & Extensions, and it waits there until you \
                    turn it on.
                    """,
                enables: "Typing through the virtual keyboard.",
                ifSkipped: otherDeliveryThanTheVirtualKeyboard)
        case .keyboardSetupAssistant:
            Explanation(
                why: """
                    The first time a new keyboard appears, macOS opens a window asking what \
                    kind it is, and that window would take your first dictation. \(app)'s \
                    helper answers it for the virtual keyboard as it starts.
                    """,
                enables: "Your first dictation goes to your app, not into a setup window.",
                ifSkipped: "Nothing here needs you. This clears itself once the keyboard helper is running.")
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
