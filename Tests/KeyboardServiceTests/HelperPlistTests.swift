import Foundation
import KeyboardService
import Testing

/// The launchd plist the app ships names the same service the client connects to.
///
/// A plist cannot read a Swift constant, so the name is written in both places, and this
/// is what keeps the two from drifting: an app whose daemon listened under one name while
/// its client dialled another would fail on the first keystroke and say only that the
/// helper could not be reached. [LAW:one-source-of-truth]
@Suite struct HelperPlistTests {
    private var plist: [String: Any] {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "App/LaunchDaemons/\(Helper.launchdLabel).plist")
            let data = try Data(contentsOf: url)
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
}
