import Foundation
import KeyboardService
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The two registrations of the helper name the same service the client connects to.
///
/// Neither a plist nor a bash script can read a Swift constant, so the name is written in
/// each, and this is what keeps the copies from drifting: a daemon that listened under one
/// name while its client dialled another would fail on the first keystroke and say only
/// that the helper could not be reached. [LAW:one-source-of-truth]
@Suite struct HelperPlistTests {
    private var plist: [String: Any] {
        get throws {
            let data = try Data(contentsOf: repository.appending(path: "App/LaunchDaemons/\(Helper.launchdLabel).plist"))
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
    }

    @Test func theBundledPlistNamesTheServiceTheClientConnectsTo() throws {
        let plist = try plist
        #expect(plist["Label"] as? String == Helper.launchdLabel)
        let services = try #require(plist["MachServices"] as? [String: Bool])
        #expect(services == [Helper.machServiceName: true])
    }

    /// SMAppService runs the program from inside the bundle, by a path relative to it.
    @Test func theBundledPlistRunsTheHelperFromInsideTheBundle() throws {
        #expect(try plist["BundleProgram"] as? String == "Contents/MacOS/lowtalker-keyboardd")
    }

    /// A helper that exits 0 has said, in the only way launchd hears, that starting it
    /// again would not help; every other end is restarted.
    @Test func theBundledPlistRestartsTheHelperAfterAnUnsuccessfulExitOnly() throws {
        #expect(try plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
    }

    @Test func theDevScriptRegistersTheServiceTheClientConnectsTo() throws {
        let script = try String(contentsOf: repository.appending(path: "scripts/keyboard-helper"), encoding: .utf8)
        let assignment = try #require(script.split(separator: "\n").first { $0.hasPrefix("SERVICE=") })
        #expect(assignment == "SERVICE=\"\(Helper.machServiceName)\"")
    }
}
