import AppKit
import ApplicationServices

/// What macOS is showing on top of every app's windows.
///
/// A system alert sits at the same screen centre a dialog does, so a frame located in the
/// app underneath it is a frame with somebody else's Allow button over it, and a click at
/// that frame's centre answers their prompt instead of the one it was aimed at. A person
/// driving the machine sees the alert appear; an agent working it alone does not, so this
/// is asked before every press the pointer makes rather than explained after it.
///
/// Read through Accessibility with the bounded messaging timeout every read here uses,
/// and deliberately **not** through System Events: a modal SecurityAgent dialog can leave
/// an AppleScript UI query waiting rather than answering it, and a modal dialog is exactly
/// the moment this question gets asked.
@MainActor
public enum SystemAlerts {
    /// The process macOS shows these alerts from. Nonisolated so the failure below can
    /// name it without hopping actors to render a message. [LAW:one-source-of-truth]
    public nonisolated static let owner = "com.apple.UserNotificationCenter"

    /// How many alert windows are on the screen. Zero when the owning process is not
    /// running, which is the usual state - it is launched to show an alert and exits
    /// again.
    ///
    /// The effectful edge only: it finds the process, asks, and hands the raw answer to
    /// `count(from:value:)` to be read. [LAW:effects-at-boundaries]
    public static func showing() throws -> Int {
        guard let owner = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.owner }) else { return 0 }
        let element = AXUIElementCreateApplication(owner.processIdentifier)
        AXUIElementSetMessagingTimeout(element, TargetApp.messagingTimeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        return try count(from: result, value: value)
    }

    /// What one answer about the owner's windows means, as a value.
    ///
    /// Pure, and the whole of the rule, for the reason `ScreenText.init(answer:)` is pure:
    /// this is the logic that decides whether a click may fire, and a test has to be able
    /// to ask it without a window server. [LAW:single-enforcer] the one place a raw
    /// `kAXWindows` answer becomes a count.
    ///
    /// [LAW:no-silent-failure] An owner that will not answer is not read as zero. "No
    /// alerts" and "no answer" would otherwise be the same value, and the one that means
    /// "go ahead and click" would be standing in for the one that means "you cannot see
    /// what is on the screen" - the same answer-shaped void `ScreenText` exists to refuse.
    nonisolated static func count(from result: AXError, value: CFTypeRef?) throws -> Int {
        switch result {
        // `.noValue` is an owner with nothing yet in the attribute, `.attributeUnsupported`
        // one whose element does not carry it at all. Neither is a refusal to answer.
        case .noValue, .attributeUnsupported: return 0
        // An owner holding no windows lands here instead, with an empty list to count.
        case .success:
            guard let windows = value as? [CFTypeRef] else { throw AlertsUnreadable.answeredWithSomethingElse }
            return windows.count
        default: throw AlertsUnreadable.refused(result)
        }
    }

    /// Proves the screen carries no system alert, for a caller about to press a button at
    /// a point it computed from an Accessibility frame. [LAW:parse-dont-validate]
    /// Derived from `showing` rather than asking again, so there is one reading of the
    /// screen and one rule about it. [LAW:one-source-of-truth]
    public static func requireNone() throws {
        let showing = try showing()
        guard showing == 0 else { throw AlertOnScreen(count: showing) }
    }
}

/// The screen carries a system alert, so a frame located underneath one cannot be clicked
/// safely: the point computed for the intended button may have the alert's own button on
/// top of it.
public struct AlertOnScreen: Error, CustomStringConvertible {
    public let count: Int

    public var description: String {
        "macOS is showing \(count) system alert\(count == 1 ? "" : "s") over everything else; a click aimed at an element underneath one could answer it instead. Dismiss the alert, then aim again"
    }
}

/// Whether anything is on top of the screen is unknown - which is not the same as nothing
/// being there.
///
/// The two cases are kept apart because they read as opposite things to whoever is
/// debugging from the message: a refusal cites the `AXError` it got, while an answer that
/// arrived in the wrong shape carries `AXError` 0 and citing that as the reason would say
/// success was the reason nothing was said. [LAW:no-silent-failure]
public enum AlertsUnreadable: Error, CustomStringConvertible {
    /// The owner refused the question.
    case refused(AXError)
    /// The owner answered `.success`, with a value that is not a list of windows.
    case answeredWithSomethingElse

    public var description: String {
        switch self {
        case .refused(let status):
            "\(SystemAlerts.owner) would not say what it is showing (AXError \(status.rawValue)); whether an alert is covering the screen is unknown"
        case .answeredWithSomethingElse:
            "\(SystemAlerts.owner) answered about its windows with something that is not a list of them; whether an alert is covering the screen is unknown"
        }
    }
}
