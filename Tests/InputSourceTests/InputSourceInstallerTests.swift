import Flavors
import Foundation
import Testing
@testable import InputSource

/// The installer's decisions that need no text input system: which bundle an app carries,
/// where it goes, and whether the copy standing there is the one it carries. The TIS steps themselves are held by the checkpoint on this Mac, since
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
        let app = FileManager.default.temporaryDirectory.appending(path: "carrier-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let carried = app.appending(path: InputSourceInstaller.carriedSubpath)
        try FileManager.default.createDirectory(at: carried, withIntermediateDirectories: true)
        _ = try signedBundle(in: carried, build: "1", name: "Never-\(UUID().uuidString).app",
                             identifier: Flavor.development.inputMethodBundleIdentifier)
        #expect(try InputSourceInstaller(flavor: .development, carrier: app).state() == .bundleNotInstalled)
    }

    /// A signed bundle on disk, the shape `place` copies: an executable, an Info.plist
    /// naming it, and an ad-hoc signature sealing both. `build` goes into the Info.plist, so
    /// two builds differ in exactly the way a rebuild does - in what the signature seals.
    private func signedBundle(
        in directory: URL, build: String, name: String = "Input-\(UUID().uuidString).app", identifier: String = "com.example.input"
    ) throws -> URL {
        let bundle = directory.appending(path: name)
        let macOS = bundle.appending(components: "Contents", "MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appending(path: "input"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "input",
            "CFBundlePackageType": "APPL", "CFBundleVersion": build,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appending(components: "Contents", "Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", bundle.path]
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
        return bundle
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "place-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory
    }

    @Test func aCopyIsPlacedWhereNothingStoodAndLeftAloneAfterwards() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let embedded = try signedBundle(in: directory, build: "1")
        let installed = directory.appending(components: "Input Methods", "Input.app")
        let staging = try #require(try InputSourceInstaller.place(embedded, at: installed)).previous
        #expect(try isDirectory(installed))
        #expect(try InputSourceInstaller.seal(of: installed) == InputSourceInstaller.seal(of: embedded))
        // Nothing stood there, so the staging directory holds nothing to keep.
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        #expect(try InputSourceInstaller.place(embedded, at: installed) == nil)
        // Only the copy is left in the install directory: no staged bundle beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path) == ["Input.app"])
    }

    /// The case that kept sandboxed apps from ever reaching the input method: a link to the
    /// very bundle this app carries is still replaced, by a real copy.
    @Test func aLinkIsReplacedByACopyEvenWhenItPointsAtTheRightBundle() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let embedded = try signedBundle(in: directory, build: "1")
        let installed = directory.appending(path: "Input.app")
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: embedded)
        #expect(!InputSourceInstaller.isCopy(installed, of: try InputSourceInstaller.seal(of: embedded)))
        let staging = try #require(try InputSourceInstaller.place(embedded, at: installed)).previous
        #expect(try isDirectory(installed))
        // The link was swapped out as a link, and its target was never touched.
        let old = staging.appending(path: "Input.app")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: old.path) == embedded.path)
        #expect(FileManager.default.fileExists(atPath: embedded.appending(components: "Contents", "Info.plist").path))
    }

    @Test func aCopyOfAnotherBuildIsReplaced() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = directory.appending(path: "Input.app")
        _ = try InputSourceInstaller.place(try signedBundle(in: directory, build: "1"), at: installed)
        let rebuilt = try signedBundle(in: directory, build: "2")
        #expect(try InputSourceInstaller.place(rebuilt, at: installed) != nil)
        #expect(try InputSourceInstaller.seal(of: installed) == InputSourceInstaller.seal(of: rebuilt))
    }

    /// The moment `install` stops processes before is the swap itself, not the start of the
    /// copy: a process launched while the copy was being made ran the old bundle, and a stamp
    /// taken before the copy would read it as launched from the new one and leave it running.
    @Test func theSwapIsStampedOnceTheNewCopyStands() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = directory.appending(path: "Input.app")
        _ = try InputSourceInstaller.place(try signedBundle(in: directory, build: "1"), at: installed)
        let rebuilt = try signedBundle(in: directory, build: "2")
        let replacement = try #require(try InputSourceInstaller.place(rebuilt, at: installed))
        // The rename is the last change to the installed name, so its status-change time
        // is when the new copy began to stand there.
        var status = stat()
        try #require(lstat(installed.path, &status) == 0)
        let stood = Date(timeIntervalSince1970: TimeInterval(status.st_ctimespec.tv_sec) + TimeInterval(status.st_ctimespec.tv_nsec) / 1e9)
        #expect(replacement.swappedAt >= stood)
    }

    /// An install runs at every launch, so a copy that cannot be swapped in must not leave
    /// its staged bundle behind each time it fails.
    @Test func aFailedSwapLeavesNothingStaged() throws {
        let directory = try scratch()
        let target = directory.appending(path: "Input Methods")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let embedded = try signedBundle(in: directory, build: "1")
        let name = "Input-\(UUID().uuidString).app"
        let installed = target.appending(path: name)
        // Where this volume's staging directories are made, found by making one.
        let probe = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
        try FileManager.default.removeItem(at: probe)
        let stagingRoot = probe.deletingLastPathComponent()
        // A directory nobody may add a name to: the copy is staged, and the rename refused.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
        #expect {
            _ = try InputSourceInstaller.place(embedded, at: installed)
        } throws: { error in
            guard case .cannotCopy = error as? InputSourceInstallFailure else { return false }
            return true
        }
        let staged = try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
            .filter { FileManager.default.fileExists(atPath: stagingRoot.appending(components: $0, name).path) }
        #expect(staged.isEmpty)
    }

    /// A copy whose files changed after it was signed still carries the same code directory
    /// hash, so the hash alone would call it current and never repair it.
    @Test func aDamagedCopyIsReplaced() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let embedded = try signedBundle(in: directory, build: "1")
        let installed = directory.appending(path: "Input.app")
        _ = try InputSourceInstaller.place(embedded, at: installed)
        try Data("damaged".utf8).write(to: installed.appending(components: "Contents", "Info.plist"))
        #expect(!InputSourceInstaller.isCopy(installed, of: try InputSourceInstaller.seal(of: embedded)))
        #expect(try InputSourceInstaller.place(embedded, at: installed) != nil)
        #expect(InputSourceInstaller.isCopy(installed, of: try InputSourceInstaller.seal(of: embedded)))
    }

    @Test func anUnsignedBundleIsRefusedByName() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsigned = directory.appending(path: "Unsigned.app")
        try FileManager.default.createDirectory(at: unsigned.appending(path: "Contents"), withIntermediateDirectories: true)
        #expect {
            _ = try InputSourceInstaller.place(unsigned, at: directory.appending(path: "Input.app"))
        } throws: { error in
            guard case .unsigned(let bundle, _) = error as? InputSourceInstallFailure else { return false }
            return bundle == unsigned
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Input.app").path))
    }

    @Test func onlySelectedIsReady() {
        #expect([InputSourceState.bundleNotInstalled, .notRegistered, .disabled, .enabled, .selected].filter(\.ready) == [.selected])
    }
}
