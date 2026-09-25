import AVFoundation
import Foundation
import IOKit.hid

/// The three privacy grants low-talker needs, read at one moment.
///
/// macOS credits a process's reading to the app responsible for it, so a process an app
/// starts reads that app's grants. That is how the app reads its own: through a process it
/// starts for each reading, because the app's own process keeps the first answer it got.
/// Measured on studious (macOS 15.0.1, 2026-09-25): the app read the microphone "turned
/// off" for 24 s after it was allowed, and sent tccd no query in that time; a fresh process
/// queries tccd on every call, and tccd names the launching app as the subject.
///
/// Accessibility is the exception, read by the app itself: its own reading is live (it read
/// "allowed" 3 s after a grant on studious). Checking it, from any process, files the app in
/// the Accessibility list switched off, so it is checked only for a setup that needs it; see
/// `Requirement.inputMonitoring`.
///
/// [LAW:one-source-of-truth] One reader answers the setup, the menu, and the gates on the
/// microphone and the tap; each takes a reading at the moment it decides.
public struct PrivacyReading: Sendable, Hashable {
    public let microphone: AVAuthorizationStatus
    public let inputMonitoring: InputMonitoringAccess
    /// Nil when the setup needs no Accessibility, so it was not checked.
    public let accessibility: Bool?

    public init(microphone: AVAuthorizationStatus, inputMonitoring: InputMonitoringAccess, accessibility: Bool?) {
        self.microphone = microphone
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
    }

    /// What `lowtalker grants` prints: this process's microphone and Input Monitoring.
    public static func lineReadHere() -> String {
        line(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            inputMonitoring: InputMonitoringAccess(held: EventTapAccess.inputMonitoring, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)))
    }

    /// A fresh reading, taken by `reader grants` - the carried CLI - as a process this one
    /// starts, so it is credited to this app; Accessibility is checked here, and only when
    /// `checkingAccessibility`.
    public static func taken(by reader: String, checkingAccessibility: Bool) throws(PrivacyReadingFailure) -> PrivacyReading {
        try PrivacyReading(
            line: run(reader, ["grants"], withinSeconds: 10),
            accessibility: checkingAccessibility ? EventTapAccess.accessibility : nil)
    }

    /// Runs the reader and answers with the line it printed.
    ///
    /// - Parameter deadline: past this the reader is stuck, and is ended. A read launched
    ///   in 10-20 ms on studious; the first run of a new binary is checked by macOS first.
    ///   Both pipes are drained while it runs, so a long crash report cannot stall it.
    private static func run(_ reader: String, _ arguments: [String], withinSeconds deadline: Int) throws(PrivacyReadingFailure) -> String {
        let command = "\(reader) \(arguments.joined(separator: " "))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: reader)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        let complaint = Pipe()
        process.standardError = complaint
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw PrivacyReadingFailure("\(command) did not start: \(error)") }
        let said = Drained(output), complained = Drained(complaint)
        let by = DispatchTime.now() + .seconds(deadline)
        guard exited.wait(timeout: by) == .success else {
            // SIGKILL rather than terminate(): a stuck reader is not asked to leave.
            kill(process.processIdentifier, SIGKILL)
            throw PrivacyReadingFailure("\(command) did not answer within \(deadline) s")
        }
        guard let line = said.text(by: by) else {
            throw PrivacyReadingFailure("\(command) exited but its output stayed open past \(deadline) s")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let how = process.terminationReason == .uncaughtSignal ? "crashed with signal" : "exited"
            let why = complained.text(by: by) ?? ""
            throw PrivacyReadingFailure("\(command) \(how) \(process.terminationStatus)\(why.isEmpty ? "" : ": \(why)")")
        }
        return line
    }

    /// What `lowtalker grants` prints, and `init(line:accessibility:)` reads back: the two
    /// grants read in a fresh process.
    public var line: String { Self.line(microphone: microphone, inputMonitoring: inputMonitoring) }

    private static func line(microphone: AVAuthorizationStatus, inputMonitoring: InputMonitoringAccess) -> String {
        "microphone=\(microphone.rawValue) inputMonitoring=\(inputMonitoring.rawValue)"
    }

    /// [LAW:parse-dont-validate] The one place the printed line becomes a reading, with
    /// Accessibility read by the process taking it.
    public init(line: String, accessibility: Bool?) throws(PrivacyReadingFailure) {
        let fields = Dictionary(
            line.split(separator: " ").map { field in
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                return (pair.first ?? "", pair.count == 2 ? pair[1] : "")
            },
            uniquingKeysWith: { first, _ in first })
        // An imported enum's init(rawValue:) accepts any Int, so the four known values are
        // named here: an unknown one is a line this build cannot read, not a crash later.
        let known: [AVAuthorizationStatus] = [.notDetermined, .restricted, .denied, .authorized]
        guard let microphone = fields["microphone"].flatMap(Int.init).flatMap({ raw in known.first { $0.rawValue == raw } }),
              let inputMonitoring = fields["inputMonitoring"].flatMap(InputMonitoringAccess.init(rawValue:))
        else { throw PrivacyReadingFailure("unreadable grants line \"\(line)\"") }
        self.init(microphone: microphone, inputMonitoring: inputMonitoring, accessibility: accessibility)
    }

    /// Both grants an event tap needs. See `EventTapAccess`.
    public var eventTapHeld: Bool { inputMonitoring == .granted && accessibility == true }

    /// The microphone as this reading found it, so a grant is minted from the same answer
    /// the setup shows. Only the authorization leaves here: asking is not something a reading
    /// can do. [LAW:types-are-the-program]
    public var microphoneAuthorization: MicrophoneAuthorization {
        MicrophonePermission(authority: ReadMicrophoneAuthority(read: microphone)).current
    }
}

/// Input Monitoring, including whether macOS has been asked yet: only then does asking
/// show a dialog.
public enum InputMonitoringAccess: String, Sendable {
    case granted
    case denied
    case undecided

    /// `held` is `EventTapAccess.inputMonitoring`, which is the measured answer to whether
    /// the tap hears keys: it reads true from Accessibility alone, where IOHID may still say
    /// unknown. IOHID only tells a "no" from never asked. [LAW:one-source-of-truth]
    init(held: Bool, _ access: IOHIDAccessType) {
        if held {
            self = .granted
            return
        }
        self = switch access {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        case kIOHIDAccessTypeUnknown: .undecided
        // [LAW:no-silent-failure] As `MicrophonePermission.parse`: an SDK this build does not know.
        default: preconditionFailure("IOHIDAccessType \(access.rawValue) is not one this build knows")
        }
    }
}

public struct PrivacyReadingFailure: Error, Hashable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A status already read. Never asked: it lives only inside `microphoneAuthorization`.
private struct ReadMicrophoneAuthority: MicrophoneAuthority {
    let read: AVAuthorizationStatus
    func status() -> AVAuthorizationStatus { read }
    func requestAccess() async -> Bool { preconditionFailure("a reading is never asked") }
}

/// A pipe read to its end on a queue of its own from the moment the reader starts, so the
/// reader never blocks on a full pipe whatever it writes.
private final class Drained: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchGroup()

    init(_ pipe: Pipe) {
        done.enter()
        DispatchQueue.global().async { [self] in
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.leave()
        }
    }

    /// Everything written, once every writer has closed its end, trimmed; nil if one still
    /// holds it open at `deadline` - a process the reader left behind.
    func text(by deadline: DispatchTime) -> String? {
        guard done.wait(timeout: deadline) == .success else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
