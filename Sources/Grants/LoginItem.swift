import ServiceManagement

/// Whether macOS opens this app when its person logs in, as the Login Items list in System
/// Settings records it.
///
/// [LAW:one-source-of-truth] That list is the one record. The app keeps no setting of its own
/// beside it, so a person who switches the app off there sees it off here too, and nothing
/// can turn it back on behind them.
public enum LoginItemStatus: Sendable, Equatable, CustomStringConvertible {
    /// Opened at login.
    case on
    /// Never chosen, or chosen off from this app.
    case off
    /// Registered, and waiting for a person to allow it in System Settings - where it lands
    /// once they have switched it off there. Only System Settings allows it.
    case requiresApproval
    /// A status macOS added after this build. Shown as the number macOS gave rather than
    /// trapping, since the menu reads the status every time it opens. [LAW:no-silent-failure]
    case unrecognized(Int)

    /// Whether the app has asked macOS to open it at login: the item is in the list, allowed
    /// there or not. What a click on the menu item turns around.
    public var chosen: Bool {
        switch self {
        case .on, .requiresApproval: true
        case .off, .unrecognized: false
        }
    }

    public var description: String {
        switch self {
        case .on: "opens at login"
        case .off: "does not open at login"
        case .requiresApproval: "waiting to be allowed under System Settings > General > Login Items"
        case .unrecognized(let raw): "macOS reports a login item status this build does not know (\(raw))"
        }
    }
}

/// A choice macOS refused, and the status it left the item in, which is what says where the
/// choice can be made instead.
public struct LoginItemRefusal: Error, CustomStringConvertible {
    public let reason: any Error
    public let status: LoginItemStatus

    /// An item the person switched off in System Settings can be allowed only there, so the
    /// refusal is answered by opening that pane at the switch. Any other refusal has nothing
    /// for them to do there.
    public var allowedOnlyInSystemSettings: Bool { status == .requiresApproval }

    public var description: String { "\(reason); \(status)" }
}

/// [LAW:effects-at-boundaries] What macOS lets an app do about its own login item, behind a
/// seam so the parsing above it runs in tests against a status a test controls.
public protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// The app as its own login item: read it, or turn it around.
public struct LoginItem {
    private let service: any LoginItemService

    public init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
    }

    public var current: LoginItemStatus { Self.parse(service.status) }

    /// Unregisters an item the app has chosen, registers one it has not, then reads back what
    /// macOS made of it. An item waiting on System Settings counts as chosen, so a click there
    /// takes it out of the list rather than asking again for what is already asked.
    /// [LAW:no-silent-failure] A refusal throws with the status read after it.
    public func toggle() throws(LoginItemRefusal) -> LoginItemStatus {
        do { try current.chosen ? service.unregister() : service.register() }
        catch { throw LoginItemRefusal(reason: error, status: current) }
        return current
    }

    /// The one place a ServiceManagement status becomes a domain value.
    private static func parse(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: .on
        // An app that was never registered reads `notFound` and one unregistered from here
        // reads `notRegistered` (both measured on macOS 15, 2026-10-03): either way, nothing
        // opens it at login.
        case .notRegistered, .notFound: .off
        case .requiresApproval: .requiresApproval
        @unknown default: .unrecognized(status.rawValue)
        }
    }
}
