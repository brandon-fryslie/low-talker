/// A macOS application identity, e.g. `com.apple.Safari`.
///
/// [LAW:one-type-per-behavior] The same type names the frontmost app in a Context and
/// the target of ActivateApp and InsertText, so a route can compare and forward them
/// without a conversion.
public struct BundleID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
