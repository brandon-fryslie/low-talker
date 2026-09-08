/// The virtual keyboard the driver extension publishes, as macOS identifies it.
///
/// [LAW:one-source-of-truth] Two very different things are built from these numbers: the
/// 24-byte parameter block that initialises the device, and the key Keyboard Setup
/// Assistant files its verdict under. They live here, together, because a device
/// initialised as one identity and onboarded as another is a Mac where the assistant
/// keeps returning and nothing says why.
public enum VirtualKeyboardIdentity {
    /// pqrs's own defaults for the virtual keyboard.
    public static let vendorID: UInt64 = 0x16c0
    public static let productID: UInt64 = 0x27db
    /// ANSI. The country code is part of the device's identity and part of the
    /// assistant's cache key, so changing it moves both at once - which is the point.
    public static let countryCode: UInt64 = 0

    /// The key `/Library/Preferences/com.apple.keyboardtype` files this device's answer
    /// under. macOS spells it `<product>-<vendor>-<country>`, in that order and in
    /// decimal - not the order the device is initialised in.
    public static var keyboardTypeKey: String { "\(productID)-\(vendorID)-\(countryCode)" }

    /// What the assistant writes once it has an answer. 40 is ANSI, and it is the
    /// layout every reverse map in this project is built against; a project that grew
    /// ISO or JIS support would have to move this and the layout map together.
    public static let ansiKeyboardType = 40

    /// Where macOS files those answers, as `defaults` names the domain.
    ///
    /// Beside the key rather than beside either process that touches it: the helper
    /// writes this file as root and onboarding reads it as the user, and a writer and a
    /// reader holding their own spellings of one path is two clocks - one of them
    /// answering about a file nobody wrote. [LAW:one-source-of-truth]
    public static let keyboardTypeDomain = "/Library/Preferences/com.apple.keyboardtype"

    /// The same thing as a file. `defaults` takes the domain and
    /// `PropertyListSerialization` takes the file, and they are one path.
    public static let keyboardTypePlist = keyboardTypeDomain + ".plist"
}
