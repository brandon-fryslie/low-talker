import Flavors
import Foundation
@testable import LowTalkerCommands
import Testing

/// The CLI acts on the installation whose bundle carries it, so the copy inside each app
/// reaches the one helper signed to admit it. Asserted against real bundles on disk, laid
/// out the way Xcode lays them out, because the answer is read from the file system.
@Suite struct CarrierTests {
    /// A bundle holding an executable at `Contents/Helpers/lowtalker`, under `identifier`.
    private func carried(by identifier: String) throws -> (executable: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let helpers = root.appending(path: "Some.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Some"], format: .xml, options: 0)
        try plist.write(to: root.appending(path: "Some.app/Contents/Info.plist"))
        let executable = helpers.appending(path: "lowtalker")
        try Data().write(to: executable)
        return (executable, root)
    }

    @Test(arguments: Flavor.allCases)
    func aCarriedCopyActsOnItsCarrier(flavor: Flavor) throws {
        let (executable, root) = try carried(by: flavor.bundleIdentifier)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FlavorOption.carrier(of: executable) == flavor)
    }

    /// A link on PATH is how a person without a checkout reaches the CLI, and the process
    /// started through it must still find the bundle the file really sits in.
    @Test func aLinkReachesTheBundleItPointsInto() throws {
        let (executable, root) = try carried(by: Flavor.release.bundleIdentifier)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appending(path: "lowtalker")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        #expect(FlavorOption.carrier(of: link) == .release)
    }

    /// Carried by something that is neither installation - a loose build, or any other app -
    /// is carried by none.
    @Test func noInstallationCarriesAnythingElse() throws {
        let (executable, root) = try carried(by: "com.example.other")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FlavorOption.carrier(of: executable) == nil)
        #expect(FlavorOption.carrier(of: root.appending(path: "lowtalker")) == nil)
    }
}
