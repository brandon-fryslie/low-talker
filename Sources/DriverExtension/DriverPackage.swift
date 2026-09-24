import CryptoKit
import Foundation

/// The public package the driver extension ships in: which release, which bytes, and who
/// signed them.
///
/// [LAW:decomposition] Apart from `DriverProbe`, which is about finding the driver on
/// this Mac: this is about the artifact that puts it there.
///
/// [LAW:one-source-of-truth] The one place these are written. `lowtalker driver install`,
/// `fetch` and `check` act on them, onboarding and `lowtalker driver pins` read them out,
/// and README.md quotes some, which `make check-docs` holds to `pins`.
///
/// Two version numbers travel together and are not the same number. The *package* carries
/// the Manager and Daemon apps; the *driver extension* inside it is what
/// `systemextensionsctl` reports. The extension version has not moved across many package
/// releases, so a package upgrade that leaves `systemextensionsctl` reading the same
/// extension version has not failed.
public enum DriverPackage {
    public static let version = "8.4.0"
    public static let extensionVersion = "1.8.0"
    public static let sha256 = "8e6c433f4e3aaa0403f6f3c72849cfcd054d52d83b53d7408771ade54f1d49a1"
    public static let signingAuthority = "Developer ID Installer: Fumihiko Takayama (\(DriverProbe.teamID))"
    /// pkgutil's line for a chain Apple issued, three-space indent and all. Matched as a
    /// whole line: a chain entry whose Common Name carried this text would satisfy a
    /// substring match.
    static let trustedStatus = "   Status: signed by a developer certificate issued by Apple for distribution"

    /// The release asset's own name, which is also what a fetched copy is saved under.
    public static var fileName: String { "Karabiner-DriverKit-VirtualHIDDevice-\(version).pkg" }

    /// pqrs's release asset for that version. Built from the version rather than written
    /// out beside it, so a version bump cannot leave a URL pointing at the old release.
    public static var url: String {
        "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v\(version)/\(fileName)"
    }

    /// [LAW:parse-dont-validate] [LAW:single-enforcer] The one judgement every package this
    /// program installs or hands on passes, whether it came from GitHub or from a release: a
    /// file that shipped beside the app is not thereby a trusted file. Three lies are caught,
    /// and the last two are one report read twice. The checksum catches bytes that are not
    /// the pinned release, a moved tag included. The status line catches an untrusted chain
    /// and the authority the wrong signer: pkgutil prints a Common Name whether or not the
    /// chain behind it is trusted, so a forged self-signed certificate survives either check
    /// taken alone.
    ///
    /// `what` names the package in the refusal.
    public static func verify(_ file: URL, as what: String) throws -> VerifiedPackage {
        guard FileManager.default.fileExists(atPath: file.path) else { throw DriverInstallRefusal("\(what) is not there") }
        let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
        guard digest.map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw DriverInstallRefusal("\(what) does not match the checksum pinned for \(version)")
        }
        let signature = try Command("/usr/sbin/pkgutil", "--check-signature", file.path).run()
        guard signature.status == 0 else { throw DriverInstallRefusal("pkgutil refused \(what): \(signature.merged)") }
        let lines = signature.stdout.split(separator: "\n").map(String.init)
        guard lines.contains(trustedStatus) else {
            throw DriverInstallRefusal("\(what) has no signature macOS trusts; pkgutil did not report '\(trustedStatus)'")
        }
        guard signature.stdout.contains(signingAuthority) else {
            throw DriverInstallRefusal("\(what) is not signed by '\(signingAuthority)'")
        }
        return VerifiedPackage(url: file)
    }
}

/// A package file `DriverPackage.verify` has judged to be the pinned release. Only that
/// function makes one, so nothing installs a file nobody judged.
public struct VerifiedPackage: Sendable {
    public let url: URL
    fileprivate init(url: URL) { self.url = url }
}

/// A verb declining to act, with the sentence that says why. Refusals are the ordinary
/// ending of an install or removal the machine is not ready for, so they are their own
/// type and the CLI prints them as they are. [LAW:no-silent-failure]
public struct DriverInstallRefusal: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
