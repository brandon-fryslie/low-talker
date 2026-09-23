import AppKit
import Carbon
import Flavors
import Foundation
import os
import Security

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
/// A copy and not a link, measured on 2026-09-23: a sandboxed app - TextEdit, Safari - reads
/// the input method's bundle before it connects to it, and the sandbox refuses that read
/// wherever a link in `~/Library/Input Methods` points outside it, so a linked input method
/// is selected everywhere and reaches only the apps that run unsandboxed. System Settings
/// lists only a bundle that is really there for the same reason. The copy is derived from the
/// bundle this app carries, and its code signature is what says whether it still matches:
/// the signature seals every file in the bundle, so a rebuild, another checkout's build and
/// an older install all read as a different copy and are replaced. [LAW:one-source-of-truth]
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
        // Installed means the copy this app carries, which is what `install` would leave: a
        // link, another build or a damaged copy reads as not installed, because each is
        // one `install` replaces. [LAW:single-enforcer]
        guard Self.isCopy(try installed(), of: try Self.seal(of: try embedded())) else { return .bundleNotInstalled }
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
        // A process of this input method started from the copy that stood there before, so
        // once that copy is replaced every one of them answers the insert port with replaced
        // code for as long as it lives; the text input system launches the next from the new
        // copy. A copy left alone leaves them alone: stopping an input method that is already
        // running the right code only disconnects every app from it, and imklaunchagent stops
        // relaunching one that keeps dying.
        if let replacement = try Self.place(embedded, at: installed) {
            stopRunning(launchedBefore: replacement.swappedAt)
            discard(replacement.previous)
        }
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

    /// A copy `place` swapped in: the moment it began to stand, and the staging directory,
    /// which holds whatever stood there before - still whole, because a process may be
    /// running from it - or nothing on a first install. The caller deletes it once no
    /// process runs from it.
    struct Replacement: Equatable {
        /// Read after the swap, so every process launched before it may be running the old
        /// copy and every process launched after it is running the new one.
        let swappedAt: Date
        let previous: URL
    }

    /// Puts a copy of `embedded` at `installed` unless what stands there already is one,
    /// answering nil when it left things alone.
    ///
    /// Staged in the system's replacement directory for this volume and swapped in with one
    /// rename where the volume can swap, so the text input system finds the old bundle or
    /// the new one and never half of either, and a crash mid-copy leaves nothing in
    /// `~/Library/Input Methods`. A copy
    /// that fails takes its staging directory with it, since an install runs at every launch
    /// and a lasting failure would otherwise leave one more copy behind each time.
    ///
    /// `swap` is `renamex_np` with `RENAME_SWAP` except in a test standing in for a volume
    /// that cannot swap.
    static func place(
        _ embedded: URL, at installed: URL,
        swap: (URL, URL) -> Int32 = { renamex_np($0.path, $1.path, UInt32(RENAME_SWAP)) }
    ) throws -> Replacement? {
        let wanted = try seal(of: embedded)
        if isCopy(installed, of: wanted) { return nil }
        let staging: URL
        do {
            try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            staging = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
        } catch {
            throw InputSourceInstallFailure.cannotCopy(from: embedded, to: installed, reason: "\(error)")
        }
        do {
            let staged = staging.appending(path: installed.lastPathComponent)
            try FileManager.default.copyItem(at: embedded, to: staged)
            // The swap exchanges the two names when both exist - a link is swapped as the
            // link, never followed. When it fails, the copy is renamed in: straight away if
            // nothing stood there (ENOENT), and otherwise - as on HFS+, which answers
            // ENOTSUP - after what stood there is moved, whole, into the staging directory.
            if swap(staged, installed) != 0 {
                let aside = staging.appending(path: "previous")
                let moved = errno == ENOENT || rename(installed.path, aside.path) == 0 || errno == ENOENT
                guard moved, rename(staged.path, installed.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return Replacement(swappedAt: Date(), previous: staging)
        } catch {
            // [LAW:no-silent-failure] A staging directory that will not go is said in the
            // same refusal, where the person reading it is already looking.
            var reason = "\(error)"
            do { try FileManager.default.removeItem(at: staging) } catch {
                reason += "; the staged copy is left at \(staging.path): \(error)"
            }
            throw InputSourceInstallFailure.cannotCopy(from: embedded, to: installed, reason: reason)
        }
    }

    /// Deletes the copy a swap put aside, once the processes running it are stopped.
    ///
    /// Said and not thrown when it fails: the new copy already stands, so refusing here would
    /// leave the input method unregistered and unselected for the sake of a folder in the
    /// system's temporary items. [LAW:no-silent-failure]
    private func discard(_ previous: URL) {
        do { try FileManager.default.removeItem(at: previous) } catch {
            Logger(subsystem: flavor.bundleIdentifier, category: "engine").error("""
                input method: the replaced copy is left at \(previous.path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// Whether what stands at `installed` is a whole copy of the bundle sealed as `seal`.
    ///
    /// A copy is its signature: the code directory hash stands for every file the
    /// signature seals, and validating the copy is what makes that true of the files as
    /// they are now rather than as they were signed. A link is no copy, whatever it points
    /// at, because a link is what a sandboxed app cannot follow. [LAW:single-enforcer] The
    /// one place that decides whether the installed input method is the one this app
    /// carries; `state` and `place` both ask it.
    static func isCopy(_ installed: URL, of seal: Data) -> Bool {
        let standing = try? FileManager.default.attributesOfItem(atPath: installed.path)[.type] as? FileAttributeType
        return standing == .typeDirectory && (try? Self.seal(of: installed)) == seal
    }

    /// The code directory hash of a bundle whose signature holds for every file it seals:
    /// one value standing for the whole bundle.
    static func seal(of bundle: URL) throws -> Data {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        var information: CFDictionary?
        if let code {
            status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
            if status == errSecSuccess { status = SecCodeCopySigningInformation(code, [], &information) }
        }
        guard status == errSecSuccess else { throw InputSourceInstallFailure.unsigned(bundle: bundle, status: status) }
        // Signing information with no hash in it is what an unsigned bundle reads as, and
        // is said as that rather than as the success status that carried it.
        guard let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
            throw InputSourceInstallFailure.unsigned(bundle: bundle, status: errSecCSUnsigned)
        }
        return hash
    }

    /// The one source with this identifier, including sources that are switched off.
    ///
    /// `includeAllInstalled` is what makes a disabled source visible at all: the default
    /// list holds only what is enabled, so without it a registered-but-off input method
    /// would read as `notRegistered` to `state`, and `install` would register it and then
    /// refuse with `notInSourceListAfterRegistering` instead of switching it on.
    static func source(named identifier: String) -> TISInputSource? {
        let query = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        let sources = TISCreateInputSourceList(query, true)?.takeRetainedValue() as? [TISInputSource]
        return sources?.first
    }

    /// Ends every running process of this flavor's input method that started before
    /// `moment`, which is when the copy they were running was replaced.
    ///
    /// Told apart by when they started and not by their path, because every path now
    /// resolves to the new copy: a process the text input system launched from it between
    /// the swap and this call is already running the right code, and stopping it would be a
    /// death for nothing. Forced, because an input method is never asked to quit by anyone
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
/// does about each is different: an app carrying no input method, or one carrying it unsigned,
/// was built wrong, a copy that would not be made is a permissions or disk problem in their
/// home folder, and a
/// bundle the text input system would not take is the identifier rule in
/// `Flavor.inputMethodBundleIdentifier` being broken by a rename.
public enum InputSourceInstallFailure: Error, Equatable, CustomStringConvertible {
    case appCarriesNoInputMethod(identifier: String, looked: URL)
    case unsigned(bundle: URL, status: OSStatus)
    case cannotCopy(from: URL, to: URL, reason: String)
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
        case let .unsigned(bundle, status):
            "the input method at \(bundle.path) has no valid code signature (OSStatus \(status)); it was built without one or has been changed since"
        case let .cannotCopy(from, to, reason):
            "cannot copy \(from.path) to \(to.path): \(reason)"
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
