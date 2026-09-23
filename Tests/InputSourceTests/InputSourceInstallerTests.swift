import Flavors
import Foundation
import Testing
@testable import InputSource

/// The installer's decisions that need no text input system: which bundle an app carries,
/// and where it goes. The TIS steps themselves are held by the checkpoint on this Mac, since
/// registering a source from a test would change the Input menu of whoever runs the suite.
@Suite struct InputSourceInstallerTests {
    /// An app bundle on disk carrying the named input method bundles, each with the given
    /// identifier - the shape project.yml's copy phase leaves.
    private func carrier(_ bundles: [(name: String, identifier: String)]) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appending(path: "carrier-\(UUID().uuidString).app")
        for bundle in bundles {
            let contents = app.appending(path: InputSourceInstaller.carriedSubpath).appending(components: bundle.name, "Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": bundle.identifier, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appending(path: "Info.plist"))
        }
        return app
    }

    @Test(arguments: Flavor.allCases)
    func theBundleIsFoundByItsIdentifierAndNotItsName(flavor: Flavor) throws {
        let other = Flavor.allCases.first { $0 != flavor }!
        // The other flavor's bundle carries the name this flavor's would, so a scan that
        // matched on names would take it.
        let app = try carrier([
            (name: "\(flavor.displayName) Input Method.app", identifier: other.inputMethodBundleIdentifier),
            (name: "Renamed.app", identifier: flavor.inputMethodBundleIdentifier),
        ])
        defer { try? FileManager.default.removeItem(at: app) }
        let installer = InputSourceInstaller(flavor: flavor, carrier: app)
        #expect(try installer.embedded().lastPathComponent == "Renamed.app")
        #expect(try installer.installed() == InputSourceInstaller.installDirectory.appending(path: "Renamed.app"))
    }

    @Test func anAppCarryingNoInputMethodSaysSoByIdentifier() throws {
        let app = try carrier([(name: "Other.app", identifier: "com.example.other")])
        defer { try? FileManager.default.removeItem(at: app) }
        let installer = InputSourceInstaller(flavor: .development, carrier: app)
        #expect(throws: InputSourceInstallFailure.appCarriesNoInputMethod(
            identifier: Flavor.development.inputMethodBundleIdentifier,
            looked: app.appending(path: InputSourceInstaller.carriedSubpath)
        )) { try installer.embedded() }
    }

    @Test func aBundleNothingHasInstalledReadsAsNotInstalled() throws {
        // A name no install has ever used, so the reading comes from the file system alone
        // and never reaches the source list.
        let app = try carrier([(name: "Never-\(UUID().uuidString).app", identifier: Flavor.development.inputMethodBundleIdentifier)])
        defer { try? FileManager.default.removeItem(at: app) }
        #expect(try InputSourceInstaller(flavor: .development, carrier: app).state() == .bundleNotInstalled)
    }

    @Test func onlySelectedIsReady() {
        #expect([InputSourceState.bundleNotInstalled, .notRegistered, .disabled, .enabled, .selected].filter(\.ready) == [.selected])
    }
}
