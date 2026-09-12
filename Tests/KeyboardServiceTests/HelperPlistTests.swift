import Flavors
import Foundation
import KeyboardService
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Every registration of every flavor's helper names the service that flavor's client
/// connects to.
///
/// Neither a plist nor a bash script can read a Swift constant, so the names are written
/// in each, and this is what keeps the copies from drifting: a daemon that listened under
/// one name while its client dialled another would fail on the first keystroke and say
/// only that the helper could not be reached. [LAW:one-source-of-truth]
///
/// [LAW:behavior-not-structure] Driven from `Flavor.allCases`, so a flavor added without
/// a plist fails here rather than at whatever later moment someone tries to run it.
@Suite struct HelperPlistTests {
    private static func plist(for flavor: Flavor) throws -> [String: Any] {
        let data = try Data(contentsOf: repository.appending(path: "App/LaunchDaemons/\(flavor.launchdLabel).plist"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test(arguments: Flavor.allCases)
    func theBundledPlistNamesTheServiceTheClientConnectsTo(flavor: Flavor) throws {
        let plist = try Self.plist(for: flavor)
        #expect(plist["Label"] as? String == flavor.launchdLabel)
        let services = try #require(plist["MachServices"] as? [String: Bool])
        #expect(services == [flavor.machServiceName: true])
    }

    /// The helper reads which installation it serves from here and from nowhere else: the
    /// binary inside both bundles is one program, so an absent or wrong argument is a
    /// daemon serving the other copy - or, as it is written to do, refusing to start.
    @Test(arguments: Flavor.allCases)
    func theBundledPlistTellsTheHelperWhichFlavorItIs(flavor: Flavor) throws {
        let arguments = try #require(try Self.plist(for: flavor)["ProgramArguments"] as? [String])
        let flag = try #require(arguments.firstIndex(of: "--flavor"), "no --flavor in \(arguments)")
        #expect(arguments.indices.contains(flag + 1))
        #expect(arguments[flag + 1] == flavor.description)
    }

    /// SMAppService runs the program from inside the bundle, by a path relative to it.
    @Test(arguments: Flavor.allCases)
    func theBundledPlistRunsTheHelperFromInsideTheBundle(flavor: Flavor) throws {
        #expect(try Self.plist(for: flavor)["BundleProgram"] as? String == "Contents/MacOS/lowtalker-keyboardd")
    }

    /// A helper that exits 0 has said, in the only way launchd hears, that starting it
    /// again would not help; every other end is restarted.
    @Test(arguments: Flavor.allCases)
    func theBundledPlistRestartsTheHelperAfterAnUnsuccessfulExitOnly(flavor: Flavor) throws {
        #expect(try Self.plist(for: flavor)["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
    }

    /// The two installations must not be one job wearing two names: a shared label or a
    /// shared service is the collision the whole design removes.
    @Test func theFlavoursPlistsShareNoName() throws {
        let labels = try Flavor.allCases.map { try #require(Self.plist(for: $0)["Label"] as? String) }
        #expect(Set(labels).count == Flavor.allCases.count, "two plists share a Label: \(labels)")
    }
}
