import Flavors
import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The app runs under App Sandbox with the microphone and two Mach names, and nothing else.
///
/// Read off the plist xcodegen renders, so a template attribute that names another flavor's
/// port, or none, fails here rather than as a sandbox denial at the first hotkey press.
/// Compared whole: an entitlement added without a measured failure behind it - a network
/// one above all, which is what the offline build exists to lack - is a finding.
@Suite struct AppEntitlementsTests {
    @Test(arguments: Flavor.allCases)
    func theAppIsSandboxedWithOnlyTheMicrophoneAndItsTwoPorts(flavor: Flavor) throws {
        let url = repository.appending(path: "App/Generated/\(flavor.displayName).entitlements")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.lastPathComponent) has not been generated; run `make test`, which runs xcodegen - `swift test` alone does not")
        let entitlements = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? NSDictionary)
        #expect(entitlements == [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.device.audio-input": true,
            "com.apple.security.temporary-exception.mach-register.global-name": [flavor.hotkeyPortName],
            "com.apple.security.temporary-exception.mach-lookup.global-name": [flavor.inputMethodPortName],
        ] as NSDictionary)
    }
}
