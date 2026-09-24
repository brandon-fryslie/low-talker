import Foundation

/// The delivery and the hotkey source an installation's app was told to use, where the app
/// keeps them: its own defaults domain, so the two installations choose apart.
///
/// [LAW:one-source-of-truth] The app writes them and every reader reads them here, under
/// one spelling of each key: the app through its standard defaults, and the CLI through
/// the app's domain, so `lowtalker onboard` reads the setup the app is actually working to.
public struct KeptChoices {
    /// Still spelled `inputMethod`, which the type no longer is, because the word on disk
    /// is every installed copy's stored answer and renaming it would ask them all again.
    static let deliveryKey = "inputMethod"
    static let hotkeySourceKey = "hotkeySource"

    private let defaults: UserDefaults

    /// - Parameter defaults: the app's own defaults. The app passes `.standard`; another
    ///   process passes `UserDefaults(suiteName:)` named by the app's bundle identifier.
    public init(_ defaults: UserDefaults) { self.defaults = defaults }

    /// The delivery chosen, or nil for an installation that has never been asked. A stored
    /// word that names no delivery reads as never asked, and the question comes back: that
    /// is the one answer to it a person can act on.
    public var delivery: Delivery? {
        get { defaults.string(forKey: Self.deliveryKey).flatMap(Delivery.init(rawValue:)) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: Self.deliveryKey) }
    }

    /// The hotkey source chosen, or nil for an installation that has never been asked.
    public var source: HotkeySource? {
        get { defaults.string(forKey: Self.hotkeySourceKey).flatMap(HotkeySource.init(rawValue:)) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: Self.hotkeySourceKey) }
    }
}
