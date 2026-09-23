import AppKit
import Carbon
import Flavors
import Foundation

/// Where this flavor's input source stands on this Mac, as the text input system reports it.
///
/// A ladder and not a set of flags: each rung is the one below it plus one more thing that
/// has happened, and `install` walks it from wherever this Mac is standing.
/// [LAW:types-are-the-program] Nothing here is remembered between launches - every reading
/// is taken from the text input system and the file system now, so a bundle the user
/// deleted by hand reads as gone at the next look rather than as whatever the last install
/// recorded. [FRAMING:representation]
public enum InputSourceState: Equatable, Sendable, CustomStringConvertible {
    /// Nothing stands at this flavor's place in `~/Library/Input Methods`.
    case bundleNotInstalled
    /// The bundle is there and the text input system holds no source for it, which is the
    /// state a bundle copied in by hand sits in until something registers it.
    case notRegistered
    /// Registered, and switched off: it is not in the Input menu and cannot be selected.
    case disabled
    /// In the Input menu, and some other source is the one in use.
    case enabled
    /// The source in use, which is the only state an insert can happen from.
    ///
    /// Kept selected for as long as the delivery is the input method, rather than selected
    /// for each press and put back after it. Measured on 2026-09-22: a source selected from
    /// this background app becomes current at once, but the app in front goes on talking to
    /// the input method it had until its own focus changes - so a press-length selection is
    /// an input method with no client for the length of the press, and every insert refused.
    /// Selected once, the source is what every app picks up as it takes focus. The input
    /// method's controller passes every key through, so typing is unchanged by it.
    case selected

    /// Whether the input method can be asked to insert.
    public var ready: Bool { self == .selected }

    public var description: String {
        switch self {
        case .bundleNotInstalled: "not installed"
        case .notRegistered: "installed, not registered"
        case .disabled: "registered, switched off"
        case .enabled: "enabled, not selected"
        case .selected: "selected"
        }
    }
}

/// Puts this flavor's input method where macOS looks for one, registers it, and switches it
/// on - with no logout, no administrator, and no step left for a person.
///
/// [LAW:decomposition] The Text Input Sources framework as this program uses it, and
/// nothing about dictation: what it is handed is a flavor and the app bundle carrying that
/// flavor's input method, and what it answers is where that flavor's source stands.
///
/// A link and not a copy, measured on 2026-09-22: macOS registers, selects and runs a bundle
/// reached through a symbolic link in `~/Library/Input Methods`, and dictation reached
/// Safari's cursor through one. The link is what keeps the two from drifting - a
/// rebuilt app is a rebuilt input method with no second install - and it is why the
/// development copy under DerivedData and a release copy under /Applications can each be
/// installed without either overwriting the other's bundle. [LAW:one-source-of-truth]
public struct InputSourceInstaller: Sendable {
    public let flavor: Flavor
    /// The app bundle carrying the input method, which is this app unless a test says
    /// otherwise. [LAW:decomposition]
    public let carrier: URL

    public init(flavor: Flavor, carrier: URL = Bundle.main.bundleURL) {
        self.flavor = flavor
        self.carrier = carrier
    }

    /// Where macOS looks for a user's input methods. The one spelling of that path.
    /// [LAW:one-source-of-truth]
    public static var installDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(components: "Library", "Input Methods")
    }

    /// Where inside an app bundle its input methods are carried, as project.yml's copy
    /// phase puts them.
    static let carriedSubpath = "Contents/Library/InputMethods"

    /// The input method bundle this app carries, found by the identifier it must have and
    /// not by its file name.
    ///
    /// [LAW:one-source-of-truth] The identifier is the fact both halves already agree on -
    /// `Flavor.inputMethodBundleIdentifier` names it and project.yml writes it into the
    /// bundle - while the file name is a display name that a rename would silently change.
    /// A scan that matched on the name would install the wrong flavor's input method the
    /// first time one was renamed, and say nothing.
    public func embedded() throws -> URL {
        let carried = carrier.appending(path: Self.carriedSubpath)
        let wanted = flavor.inputMethodBundleIdentifier
        let contents = (try? FileManager.default.contentsOfDirectory(at: carried, includingPropertiesForKeys: nil)) ?? []
        for candidate in contents where candidate.pathExtension == "app" {
            if Bundle(url: candidate)?.bundleIdentifier == wanted { return candidate }
        }
        throw InputSourceInstallFailure.appCarriesNoInputMethod(identifier: wanted, looked: carried)
    }

    /// Where this flavor's input method stands once installed, which takes its name from
    /// the bundle being installed rather than coining a second one.
    public func installed() throws -> URL {
        Self.installDirectory.appending(path: try embedded().lastPathComponent)
    }

    /// What this Mac says about this flavor's source, right now.
    ///
    /// [LAW:parse-dont-validate] Read in the ladder's own order, so each reading is taken
    /// only where the one below it already held: a source list queried for a bundle that is
    /// not installed would answer about somebody else's leftovers.
    public func state() throws -> InputSourceState {
        let installed = try installed()
        // `fileExists` follows the link, which is the question being asked: a link whose
        // target a `make clean` took away is not an installed input method, and reading it
        // as one would leave `install` with nothing to repair.
        guard FileManager.default.fileExists(atPath: installed.path) else { return .bundleNotInstalled }
        guard let source = Self.source(named: flavor.inputSourceIdentifier) else { return .notRegistered }
        guard Self.isEnabled(source) else { return .disabled }
        return Self.isSelected(source) ? .selected : .enabled
    }

    /// Walks the ladder from wherever this Mac stands to `selected`, doing only the steps
    /// that are not already done.
    ///
    /// [LAW:no-silent-failure] Every step that can refuse says which step it was by name,
    /// and the register step is checked against the source list rather than against its own
    /// status: `TISRegisterInputSource` answers `noErr` for bundles it does not take, which
    /// `Flavor.inputMethodBundleIdentifier` records being measured. A status believed here
    /// would leave an input method that reads as installed and never answers.
    ///
    /// Async and on the main actor because the answer arrives there. Measured on 2026-09-22:
    /// a process's source list is its own copy, refreshed by a notification its main run loop
    /// delivers, so a register followed by a lookup in the same turn reads the list from
    /// before the register and finds nothing - while a fresh process, asked at that moment,
    /// finds the source. The lookup is therefore awaited, with the main run loop free to take
    /// the refresh, for up to `settling`; a source still absent after that is the silent
    /// refusal and is said as one.
    @MainActor
    @discardableResult
    public func install(settling: Duration = .seconds(3)) async throws -> InputSourceState {
        let embedded = try embedded()
        let installed = try installed()
        // Linked unless what stands there is already a link to this app's own bundle: a copy
        // from an older install or a link to another checkout is the wrong input method for
        // this app, and reading only "is something there" would leave it in place for good.
        let relinked = (try? FileManager.default.destinationOfSymbolicLink(atPath: installed.path)) != embedded.path
        if relinked { try link(embedded, to: installed) }
        // A process of this input method is running the bundle now installed only if it
        // started after that bundle was built and after the link last changed; any other is
        // running replaced code, and answers the insert port with it for as long as it lives.
        // A rebuild in place is the common case: the link is unchanged, the binary is not.
        stopRunning(launchedBefore: relinked ? .distantFuture : try builtAt(embedded))
        // Registered unconditionally rather than only when `notRegistered`: registering a
        // source already known is how the text input system is told the bundle behind it
        // changed, which is exactly what a rebuilt development copy needs and costs nothing
        // on a copy that did not.
        let status = TISRegisterInputSource(installed as CFURL)
        guard status == noErr else {
            throw InputSourceInstallFailure.registrationRefused(bundle: installed, status: status)
        }
        guard let source = try await Self.source(named: flavor.inputSourceIdentifier, within: settling) else {
            throw InputSourceInstallFailure.notInSourceListAfterRegistering(
                identifier: flavor.inputSourceIdentifier, bundle: installed)
        }
        if !Self.isEnabled(source) {
            let enabled = TISEnableInputSource(source)
            guard enabled == noErr else {
                throw InputSourceInstallFailure.enableRefused(identifier: flavor.inputSourceIdentifier, status: enabled)
            }
        }
        if !Self.isSelected(source) {
            let selected = TISSelectInputSource(source)
            guard selected == noErr else {
                throw InputSourceInstallFailure.selectRefused(identifier: flavor.inputSourceIdentifier, status: selected)
            }
        }
        // Read back rather than believed, for the reason the lookup above is: the select is
        // answered `noErr` before this process's list says so, and it can be answered
        // `noErr` and not take, as it does while an app holds Secure Event Input.
        guard try await Self.source(named: flavor.inputSourceIdentifier, within: settling, where: Self.isSelected) != nil else {
            throw InputSourceInstallFailure.notSelectedAfterSelecting(identifier: flavor.inputSourceIdentifier)
        }
        return .selected
    }

    /// When the embedded bundle's executable was last written, which is when the build a
    /// process ought to be running was made.
    private func builtAt(_ embedded: URL) throws -> Date {
        guard let executable = Bundle(url: embedded)?.executableURL else {
            throw InputSourceInstallFailure.appCarriesNoInputMethod(identifier: flavor.inputMethodBundleIdentifier, looked: embedded)
        }
        return try executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantFuture
    }

    /// The link itself, replacing whatever stood there.
    ///
    /// Replaced rather than left alone, because what stands there may be a link to another
    /// checkout, a copy from an older install, or a link whose target is gone - and all
    /// three are "the wrong input method for this app", which is the one thing an install
    /// exists to fix. [LAW:single-enforcer]
    private func link(_ embedded: URL, to installed: URL) throws {
        do {
            try FileManager.default.createDirectory(at: Self.installDirectory, withIntermediateDirectories: true)
            // `removeItem` on a symbolic link removes the link and not its target, which is
            // what makes replacing a link to a DerivedData build safe.
            if FileManager.default.fileExists(atPath: installed.path) || (try? installed.checkResourceIsReachable()) != nil {
                try? FileManager.default.removeItem(at: installed)
            }
            try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: embedded)
        } catch {
            throw InputSourceInstallFailure.cannotLink(from: embedded, to: installed, reason: "\(error)")
        }
    }

    /// The one source with this identifier, including sources that are switched off.
    ///
    /// `includeAllInstalled` is what makes a disabled source visible at all: the default
    /// list holds only what is enabled, so a registered-but-off input method would read as
    /// never registered and `install` would relink a bundle that was already in place.
    static func source(named identifier: String) -> TISInputSource? {
        let query = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        let sources = TISCreateInputSourceList(query, true)?.takeRetainedValue() as? [TISInputSource]
        return sources?.first
    }

    /// Ends every running process of this flavor's input method that started before
    /// `moment`, which the text input system launches again from the bundle now installed.
    ///
    /// Told apart by when they started and not by their path: after a relink every path
    /// resolves through the new link to the new bundle, so a path cannot say which code a
    /// process is running. Forced, because an input method is never asked to quit by anyone
    /// and does not answer the request, and it holds nothing to lose: the client is the
    /// document.
    @MainActor
    private func stopRunning(launchedBefore moment: Date) {
        for process in NSRunningApplication.runningApplications(withBundleIdentifier: flavor.inputMethodBundleIdentifier)
        where (process.launchDate ?? .distantPast) < moment {
            process.forceTerminate()
        }
    }

    /// The source, looked for until it appears reading as `holds` says, or `deadline` passes.
    ///
    /// Each miss suspends rather than blocks, which is the point: suspended, the main actor's
    /// run loop is free to deliver the refresh that makes the next look succeed. A blocking
    /// wait here would hold off the very notification it was waiting for.
    /// [LAW:no-ambient-temporal-coupling]
    @MainActor
    static func source(
        named identifier: String, within deadline: Duration, where holds: (TISInputSource) -> Bool = { _ in true }
    ) async throws -> TISInputSource? {
        let clock = ContinuousClock()
        let giveUp = clock.now + deadline
        while true {
            if let found = source(named: identifier), holds(found) { return found }
            if clock.now >= giveUp { return nil }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func isEnabled(_ source: TISInputSource) -> Bool { flag(kTISPropertyInputSourceIsEnabled, of: source) }

    static func isSelected(_ source: TISInputSource) -> Bool { flag(kTISPropertyInputSourceIsSelected, of: source) }

    private static func flag(_ property: CFString, of source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, property) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
}

/// A step of the install that refused, named as the step it was.
///
/// [LAW:no-silent-failure] One case per step rather than one message, because what a person
/// does about each is different: an app carrying no input method was built wrong, a link
/// that would not be made is a permissions or disk problem in their home folder, and a
/// bundle the text input system would not take is the identifier rule in
/// `Flavor.inputMethodBundleIdentifier` being broken by a rename.
public enum InputSourceInstallFailure: Error, Equatable, CustomStringConvertible {
    case appCarriesNoInputMethod(identifier: String, looked: URL)
    case cannotLink(from: URL, to: URL, reason: String)
    case registrationRefused(bundle: URL, status: OSStatus)
    /// The register step answered `noErr` and the source is still not in the list, which is
    /// what a bundle macOS silently declines looks like from here.
    case notInSourceListAfterRegistering(identifier: String, bundle: URL)
    case enableRefused(identifier: String, status: OSStatus)
    case selectRefused(identifier: String, status: OSStatus)
    case notSelectedAfterSelecting(identifier: String)

    public var description: String {
        switch self {
        case let .appCarriesNoInputMethod(identifier, looked):
            "this build carries no input method with identifier \(identifier) in \(looked.path); it was built without one"
        case let .cannotLink(from, to, reason):
            "cannot link \(to.path) to \(from.path): \(reason)"
        case let .registrationRefused(bundle, status):
            "the text input system refused to register \(bundle.path): OSStatus \(status)"
        case let .notInSourceListAfterRegistering(identifier, bundle):
            "the text input system took \(bundle.path) without complaint and still lists no source \(identifier); "
                + "the bundle identifier is one macOS declines silently"
        case let .enableRefused(identifier, status):
            "the text input system refused to switch on \(identifier): OSStatus \(status)"
        case let .selectRefused(identifier, status):
            "the text input system refused to select \(identifier): OSStatus \(status)"
        case let .notSelectedAfterSelecting(identifier):
            "\(identifier) was selected and is not the current input source; an app holding secure keyboard entry keeps input methods off"
        }
    }
}
