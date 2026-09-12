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

    /// The other registration path names the same things. `scripts/keyboard-helper` writes
    /// its own plist into /Library/LaunchDaemons, so it keeps a second copy of every name
    /// here - and a script that bootstrapped one label while the client dialled another
    /// would leave a root daemon nobody can reach, which is what 3ti.13 was.
    ///
    /// Read back by running the script rather than by grepping its assignments, because
    /// the development names are built from the release ones and a grep hands back the
    /// template instead of the value. `names` resolves them exactly as `install` does, so
    /// what is compared is what the script acts under. [LAW:one-source-of-truth]
    @Test(arguments: Flavor.allCases)
    func theScriptRegistersTheServiceTheClientConnectsTo(flavor: Flavor) throws {
        let names = try Self.names(of: flavor)
        #expect(names["flavor"] == flavor.description)
        #expect(names["label"] == flavor.launchdLabel)
        #expect(names["service"] == flavor.machServiceName)
        #expect(names["plist"] == "/Library/LaunchDaemons/\(flavor.launchdLabel).plist")
    }

    /// A word that is neither flavor must not resolve to names at all: the next thing the
    /// script would do with them is `sudo tee` a plist. [LAW:no-silent-failure]
    @Test func theScriptRefusesAFlavorItDoesNotKnow() throws {
        let (status, _) = try Self.run(["names", "neither"])
        #expect(status != 0, "keyboard-helper accepted a flavor that is not one")
    }

    private static func run(_ arguments: [String]) throws -> (status: Int32, printed: String) {
        let script = Process()
        script.executableURL = repository.appending(path: "scripts/keyboard-helper")
        script.arguments = arguments
        let output = Pipe()
        script.standardOutput = output
        script.standardError = Pipe()
        try script.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        script.waitUntilExit()
        return (script.terminationStatus, String(decoding: printed, as: UTF8.self))
    }

    private static func names(of flavor: Flavor) throws -> [String: String] {
        let (status, printed) = try run(["names", flavor.description])
        try #require(status == 0, "keyboard-helper names \(flavor) exited \(status)")
        var names: [String: String] = [:]
        for line in printed.split(separator: "\n") {
            let field = line.split(separator: "\t", maxSplits: 1)
            try #require(field.count == 2, "not a name and a value: \(line)")
            names[String(field[0])] = String(field[1])
        }
        return names
    }

    /// The two installations must not be one job wearing two names: a shared label or a
    /// shared service is the collision the whole design removes.
    @Test func theFlavoursPlistsShareNoName() throws {
        let labels = try Flavor.allCases.map { try #require(Self.plist(for: $0)["Label"] as? String) }
        #expect(Set(labels).count == Flavor.allCases.count, "two plists share a Label: \(labels)")
    }
}
