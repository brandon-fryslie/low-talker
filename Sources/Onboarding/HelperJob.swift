import DriverExtension
import Flavors
import Foundation

/// The keyboard helper as a LaunchDaemon: read, installed and removed by the CLI each app
/// carries, so an agent brings a helper up on a Mac with no checkout and nobody has to
/// click an approval. `SMAppService` is the app's path in and waits on that click; this
/// path runs under sudo instead. Same binary either way, and one label per flavor, so the
/// two paths are two claimants on one record and launchd refuses a second bootstrap.
///
/// [LAW:one-source-of-truth] The one installer. Every name it writes comes from `Flavor`
/// and every program from `Carrier`, so nothing here can register one label while a
/// client dials another.
public enum HelperJob {
    /// What `launchctl print system/<label>` said about the job under a flavor's label.
    struct Record: Equatable {
        /// Where the job came from. Measured on this Mac, 2026-09-12, against the running
        /// release app and its plist-installed counterpart:
        ///
        ///   SMAppService:              path = (submitted by smd.919)
        ///   launchctl bootstrap:       path = /Library/LaunchDaemons/<label>.plist
        let path: String
        /// The executable the job runs, nil when launchd names none.
        let program: URL?
        /// Whether the job holds the flavor's Mach service. The endpoint is handed out at
        /// load, so a job that holds the service names it; a job that asked and lost simply
        /// has no such entry - launchd does not make the loser loud.
        ///
        /// At load, and not at check-in, which is the reading that looks wrong. Measured
        /// with a job whose program is `sleep`, so it never checks a service in at all:
        /// `state = running`, and the endpoint already named, with `active = 0`. So a
        /// helper between its own start and `listener.resume()` - it files this keyboard's
        /// answer in that window - already reads as holding the service, which is what the
        /// assistant's row needs it to say.
        let holdsTheService: Bool

        /// A job loaded from a plist in /Library/LaunchDaemons rather than the app's
        /// registration. The path must *start* there: the app's own plist sits under
        /// `Contents/Library/LaunchDaemons/` in its bundle.
        var loadedFromLaunchDaemons: Bool { path.hasPrefix("/Library/LaunchDaemons/") }

        /// [LAW:parse-dont-validate] nil for the one refusal that is an answer - launchd
        /// has never heard of the label - and a throw for every other, because an unread
        /// launchd reported as "no job" sends a reader to approve a login item that is
        /// already approved, or an install to write over the app's job.
        /// [LAW:no-silent-failure]
        init?(_ printed: Command.Output, label: String, service: String) throws {
            guard printed.status == 0 else {
                guard printed.merged.contains("Could not find service") else {
                    throw OnboardingUnreadable.launchdRefused(label: label, status: printed.status, complaint: printed.merged)
                }
                return nil
            }
            // A field is the job's own line, not one nested beneath it: `stderr path` is
            // not `path`, and the service name in the environment block is spelled
            // without the `= {` an endpoint carries.
            let lines = printed.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            func field(_ name: String) -> String {
                lines.first { $0.hasPrefix("\(name) = ") }.map { String($0.dropFirst("\(name) = ".count)) } ?? ""
            }
            path = field("path")
            // A record naming no path says nothing about who holds the label, and nothing
            // is not an answer to act on. [LAW:no-silent-failure]
            guard !path.isEmpty else { throw OnboardingUnreadable.noPath(label: label, record: printed.stdout) }
            let program = field("program")
            self.program = program.isEmpty ? nil : URL(fileURLWithPath: program)
            holdsTheService = printed.stdout.contains("\"\(service)\" = {")
        }
    }

    /// What `helper install` and `helper remove` refuse to do, each said as the sentence
    /// the reader acts on.
    public enum Refusal: Error, CustomStringConvertible, Equatable {
        case notRoot
        case noHelper(String)
        case signedAdHoc(String)
        case unreadableSignature(path: String, said: String)
        case heldByTheApp(label: String, path: String)
        case launchctl(verb: String, status: Int32, said: String)
        case lostTheService(service: String)

        public var description: String {
            switch self {
            case .notRoot:
                "a LaunchDaemon is written and loaded as root: run this under sudo"
            case .noHelper(let path):
                "no keyboard helper at \(path), which is where this lowtalker's own is shipped"
            case .signedAdHoc(let path):
                "\(path) is signed ad hoc, so it would admit no caller and refuses to start; build it with make helper, which signs it"
            case .unreadableSignature(let path, let said):
                "codesign could not read \(path): \(said)"
            case .heldByTheApp(let label, let path):
                """
                \(label) is held by the app's own registration, through SMAppService - launchd \
                reports it at path = \(path). Removing it would take its Background Task \
                Management record with it, so it is left alone. Quit the app and turn it off in \
                Login Items & Extensions instead.
                """
            case .launchctl(let verb, let status, let said):
                "launchctl \(verb) exited \(status)\(said.isEmpty ? "" : ": \(said)")"
            case .lostTheService(let service):
                """
                launchd gave \(service) to another claimant, so the job was taken back down \
                rather than left running unreachable. A helper started by hand, or a job under \
                another label naming this service, holds it: pgrep -fl lowtalker-keyboardd; \
                sudo grep -l '>\(service)<' /Library/LaunchDaemons/*.plist
                """
            }
        }
    }

    /// The command a step names, spelled so it pastes into a shell whatever the path holds.
    public static func command(_ cli: String, _ verb: String, flavor: Flavor) -> String {
        "sudo \(Command.quoted(cli)) helper \(verb) --flavor \(flavor)"
    }

    /// Where this flavor's job is written.
    public static func plistPath(for flavor: Flavor) -> String { "/Library/LaunchDaemons/\(flavor.launchdLabel).plist" }

    /// The job, as the plist that describes it. Pure, so the names it carries are held to
    /// `Flavor` by a test with no launchd to ask.
    ///
    /// KeepAlive after an unsuccessful exit only: the helper exits 0 on purpose when
    /// starting again would not help, and that is the one exit launchd can be told not to
    /// restart. Its stderr goes under /Library/Logs, which only root and admins may write:
    /// a fixed name under /tmp is a file anyone may plant for root to open.
    public static func plist(for flavor: Flavor, helper: URL) -> [String: Any] {
        [
            "Label": flavor.launchdLabel,
            "ProgramArguments": [helper.path, "--flavor", flavor.description],
            "MachServices": [flavor.machServiceName: true],
            "KeepAlive": ["SuccessfulExit": false],
            "StandardErrorPath": "/Library/Logs/\(flavor.launchdLabel).crash.log",
        ]
    }

    /// Loads `helper` as this flavor's LaunchDaemon, replacing a job an earlier install
    /// loaded and never the app's own registration. A failure leaves no job under the
    /// label, the earlier one included: install again once it is fixed.
    public static func install(flavor: Flavor, helper: URL) throws -> String {
        guard geteuid() == 0 else { throw Refusal.notRoot }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw Refusal.noHelper(helper.path) }
        // A helper signed ad hoc admits no caller and refuses to start, for a reason it
        // logs; said here too, before a job is loaded that would only start and stop.
        let signature = try Command("/usr/bin/codesign", "-dvv", helper.path).run()
        guard signature.status == 0 else { throw Refusal.unreadableSignature(path: helper.path, said: signature.merged) }
        guard signature.merged.split(separator: "\n").contains(where: { $0.hasPrefix("Authority=") }) else {
            throw Refusal.signedAdHoc(helper.path)
        }
        // [LAW:single-enforcer] launchd refuses a second job under a held label, and that
        // refusal is why a flavor's label and service are one name. So the holder is read
        // once and answered - a job an install loaded is replaced, the app's is refused -
        // never cleared blind.
        let holder = try record(for: flavor)
        if let holder, !holder.loadedFromLaunchDaemons { throw Refusal.heldByTheApp(label: flavor.launchdLabel, path: holder.path) }
        // The job an earlier install loaded goes first, with its plist whatever that is
        // called, or it would load at the next boot and hold the label against this one.
        // So every failure below ends in one state: nothing under the label, loaded or on
        // disk, and the plist written here goes back out rather than loading at the next
        // boot ahead of the app. [LAW:no-ambient-temporal-coupling] [LAW:no-silent-failure]
        if let holder {
            try succeed(Command("/bin/launchctl", "bootout", "system/\(flavor.launchdLabel)"))
            try discard(holder.path)
        }
        let path = plistPath(for: flavor)
        do {
            let written = try PropertyListSerialization.data(fromPropertyList: plist(for: flavor, helper: helper), format: .xml, options: 0)
            try written.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: path)
            try succeed(Command("/bin/launchctl", "bootstrap", "system", path))
            // A job that did not get the endpoint is taken back down: left loaded it would be
            // a root process nobody can reach, restarted by KeepAlive forever.
            guard try record(for: flavor)?.holdsTheService == true else {
                try succeed(Command("/bin/launchctl", "bootout", "system/\(flavor.launchdLabel)"))
                throw Refusal.lostTheService(service: flavor.machServiceName)
            }
        } catch {
            try discard(path)
            throw error
        }
        return "loaded \(helper.path) as \(flavor.launchdLabel), from \(path)"
    }

    /// Removes every job an install loaded under this flavor's label, and never the app's.
    ///
    /// This flavor's plist goes whoever holds the label: with no job loaded from it, it is
    /// inert until the next boot, where it loads before the app registers and holds the
    /// label against it. A holder left running is named rather than passed over.
    /// [LAW:no-silent-failure]
    public static func remove(flavor: Flavor) throws -> String {
        guard geteuid() == 0 else { throw Refusal.notRoot }
        let holder = try record(for: flavor)
        let path = plistPath(for: flavor)
        try discard(path)
        guard let holder else { return "no job held \(flavor.launchdLabel)" }
        guard holder.loadedFromLaunchDaemons else { throw Refusal.heldByTheApp(label: flavor.launchdLabel, path: holder.path) }
        try succeed(Command("/bin/launchctl", "bootout", "system/\(flavor.launchdLabel)"))
        if holder.path != path { try discard(holder.path) }
        return "removed the job under \(flavor.launchdLabel)"
    }

    static func record(for flavor: Flavor) throws -> Record? {
        try Record(
            Command("/bin/launchctl", "print", "system/\(flavor.launchdLabel)").run(),
            label: flavor.launchdLabel, service: flavor.machServiceName)
    }

    /// A plist gone, whether or not it was there to begin with.
    private static func discard(_ path: String) throws {
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    }

    private static func succeed(_ command: Command) throws {
        let done = try command.run()
        guard done.status == 0 else { throw Refusal.launchctl(verb: command.arguments[0], status: done.status, said: done.merged) }
    }
}
