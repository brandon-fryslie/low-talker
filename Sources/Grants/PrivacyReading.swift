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
    ///   Output is read after exit: the line is a few dozen bytes, inside a pipe's buffer.
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
        guard exited.wait(timeout: .now() + .seconds(deadline)) == .success else {
            process.terminate()
            throw PrivacyReadingFailure("\(command) did not answer within \(deadline) s")
        }
        let line = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let how = process.terminationReason == .uncaughtSignal ? "crashed with signal" : "exited"
            let said = String(decoding: complaint.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrivacyReadingFailure("\(command) \(how) \(process.terminationStatus)\(said.isEmpty ? "" : ": \(said)")")
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

    /// The microphone as `MicrophonePermission` sees it through this reading, so a grant is
    /// minted from the same answer the setup shows. Asking still asks this process.
    public var microphonePermission: MicrophonePermission {
        MicrophonePermission(authority: ReadMicrophoneAuthority(read: microphone))
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

public struct PrivacyReadingFailure: Error, Hashable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A status already read, and asking done by this process.
private struct ReadMicrophoneAuthority: MicrophoneAuthority {
    let read: AVAuthorizationStatus
    func status() -> AVAuthorizationStatus { read }
    func requestAccess() async -> Bool { await SystemMicrophoneAuthority().requestAccess() }
}
