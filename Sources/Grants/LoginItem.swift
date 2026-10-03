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
    /// macOS cannot find this copy of the app to register, which is a copy that is not where
    /// it was installed.
    case notFound

    public var description: String {
        switch self {
        case .on: "opens at login"
        case .off: "does not open at login"
        case .requiresApproval: "waiting to be allowed under System Settings > General > Login Items"
        case .notFound: "macOS cannot find this copy of the app to open at login"
        }
    }
}

/// [LAW:effects-at-boundaries] What macOS lets an app do about its own login item, behind a
/// seam so the parsing above it runs in tests against a status a test controls.
public protocol LoginItemService: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}
extension SMAppService: @retroactive @unchecked Sendable {}

/// The app as its own login item: read it, or choose it.
public struct LoginItem: Sendable {
    private let service: any LoginItemService

    public init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
    }

    public var current: LoginItemStatus { Self.parse(service.status) }

    /// Registers or unregisters, then reads back what macOS made of it. A choice macOS refused
    /// throws, and the status read after is what says why: a login item switched off in System
    /// Settings is one only System Settings can allow.
    /// [LAW:no-silent-failure]
    public func choose(_ on: Bool) throws -> LoginItemStatus {
        try on ? service.register() : service.unregister()
        return current
    }

    /// The one place a ServiceManagement status becomes a domain value.
    private static func parse(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: .on
        case .notRegistered: .off
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        // [LAW:no-silent-failure] A status this build has no meaning for is an SDK the code
        // has not been updated for, not a state to show as one of the four above.
        @unknown default: preconditionFailure("SMAppService.Status \(status.rawValue) is not one this build knows")
        }
    }
}
