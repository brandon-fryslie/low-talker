import Flavors
import Foundation
import Testing
@testable import InputSource

/// Which installed bundle is this flavor's, the one decision that needs no text input system.
/// The TIS steps themselves are held by the checkpoint on a Mac, since registering a source
/// from a test would change the Input menu of whoever runs the suite.
@Suite struct InstalledInputMethodTests {
    /// A folder standing in for `/Library/Input Methods`, holding the named bundles, each with
    /// the given identifier.
    private func inputMethods(_ bundles: [(name: String, identifier: String)]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "input-methods-\(UUID().uuidString)")
        for bundle in bundles {
            let contents = directory.appending(components: bundle.name, "Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": bundle.identifier, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appending(path: "Info.plist"))
        }
        return directory
    }

    @Test(arguments: Flavor.allCases)
    func theBundleIsFoundByItsIdentifierAndNotItsName(flavor: Flavor) throws {
        let other = Flavor.allCases.first { $0 != flavor }!
        // The other flavor's bundle carries the name this flavor's would, so a scan that
        // matched on names would take it.
        let directory = try inputMethods([
            (name: "\(flavor.displayName) Input Method.app", identifier: other.inputMethodBundleIdentifier),
            (name: "Renamed.app", identifier: flavor.inputMethodBundleIdentifier),
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try InstalledInputMethod(flavor: flavor, directory: directory).bundle().lastPathComponent == "Renamed.app")
    }

    @Test func anInputMethodNotInstalledSaysSoByIdentifier() throws {
        let directory = try inputMethods([(name: "Other.app", identifier: "com.example.other")])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: InputMethodFailure.notInstalled(
            identifier: Flavor.development.inputMethodBundleIdentifier, looked: directory
        )) { try InstalledInputMethod(flavor: .development, directory: directory).bundle() }
    }

    @Test func aMissingFolderIsNotInstalledAndAnUnreadableOneSaysWhy() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "input-methods-\(UUID().uuidString)")
        #expect(throws: InputMethodFailure.notInstalled(
            identifier: Flavor.development.inputMethodBundleIdentifier, looked: missing
        )) { try InstalledInputMethod(flavor: .development, directory: missing).bundle() }

        let unreadable = try inputMethods([(name: "Other.app", identifier: "com.example.other")])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
            try? FileManager.default.removeItem(at: unreadable)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        #expect(throws: CocoaError.self) { try InstalledInputMethod(flavor: .development, directory: unreadable).bundle() }
    }
}
