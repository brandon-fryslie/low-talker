import AVFoundation
import ApplicationServices
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
/// [LAW:one-source-of-truth] One reader answers the setup, the menu, and the gates on the
/// microphone and the tap; each takes a reading at the moment it decides.
public struct PrivacyReading: Sendable, Hashable {
    public let microphone: AVAuthorizationStatus
    public let inputMonitoring: InputMonitoringAccess
    public let accessibility: Bool

    public init(microphone: AVAuthorizationStatus, inputMonitoring: InputMonitoringAccess, accessibility: Bool) {
        self.microphone = microphone
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
    }

    /// This process's own answers. Fresh in a process that has just started; a long-running
    /// one may be answered from what it read before.
    public static func here() -> PrivacyReading {
        PrivacyReading(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            inputMonitoring: InputMonitoringAccess(held: EventTapAccess.inputMonitoring, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)),
            accessibility: EventTapAccess.accessibility)
    }

    /// A fresh reading, taken by `reader grants` - the carried CLI - as a process this one
    /// starts, so it is credited to this app.
    public static func taken(by reader: String) throws(PrivacyReadingFailure) -> PrivacyReading {
        try run(reader, ["grants"])
    }

    /// Asks macOS for `grant` from a fresh process, then reads again. The asking is done
    /// there for the reason the reading is: this app's own process can answer a request
    /// from what it read before and never reach tccd - measured on studious, where the
    /// app's `CGRequestListenEventAccess` after a reset sent tccd nothing and showed no
    /// dialog. Off the main actor, since a request waits for the person's answer.
    public static func asking(for grant: PrivacyGrant, by reader: String) async throws(PrivacyReadingFailure) -> PrivacyReading {
        let result = await Task.detached { Result { () throws(PrivacyReadingFailure) in try run(reader, ["grants", "--ask", grant.rawValue]) } }.value
        return try result.get()
    }

    /// How long a reading may take. A launch measured 10-20 ms on studious; a reader that
    /// has not answered by this is stuck, and the app's menu waits on it.
    private static let deadline: DispatchTimeInterval = .seconds(2)

    private static func run(_ reader: String, _ arguments: [String]) throws(PrivacyReadingFailure) -> PrivacyReading {
        let command = "\(reader) \(arguments.joined(separator: " "))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: reader)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw PrivacyReadingFailure("\(command) did not start: \(error)") }
        // The line is a few dozen bytes, well inside a pipe's buffer, so waiting before
        // reading cannot deadlock.
        guard exited.wait(timeout: .now() + deadline) == .success else {
            process.terminate()
            throw PrivacyReadingFailure("\(command) did not answer within \(deadline)")
        }
        let line = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let how = process.terminationReason == .uncaughtSignal ? "crashed with signal" : "exited"
            throw PrivacyReadingFailure("\(command) \(how) \(process.terminationStatus)")
        }
        return try PrivacyReading(line: line)
    }

    /// The reading as `lowtalker grants` prints it, and as `init(line:)` reads it back.
    public var line: String {
        "microphone=\(microphone.rawValue) inputMonitoring=\(inputMonitoring.rawValue) accessibility=\(accessibility)"
    }

    /// [LAW:parse-dont-validate] The one place the printed line becomes a reading.
    public init(line: String) throws(PrivacyReadingFailure) {
        let fields = Dictionary(
            line.split(separator: " ").map { field in
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                return (pair.first ?? "", pair.count == 2 ? pair[1] : "")
            },
            uniquingKeysWith: { first, _ in first })
        guard let microphone = fields["microphone"].flatMap(Int.init).flatMap(AVAuthorizationStatus.init(rawValue:)),
              let inputMonitoring = fields["inputMonitoring"].flatMap(InputMonitoringAccess.init(rawValue:)),
              let accessibility = fields["accessibility"].flatMap(Bool.init)
        else { throw PrivacyReadingFailure("unreadable grants line \"\(line)\"") }
        self.init(microphone: microphone, inputMonitoring: inputMonitoring, accessibility: accessibility)
    }

    /// Both grants an event tap needs. See `EventTapAccess`.
    public var eventTapHeld: Bool { inputMonitoring == .granted && accessibility }

    /// The microphone as `MicrophonePermission` sees it through this reading, so a grant is
    /// minted from the same answer the setup shows. Asking still asks this process.
    public var microphonePermission: MicrophonePermission {
        MicrophonePermission(authority: ReadMicrophoneAuthority(read: microphone))
    }
}

/// A grant asked for from a fresh process. Only Input Monitoring: the app's own request for
/// it was measured sending tccd nothing, while the microphone's and Accessibility's, asked
/// in the app, each raised their dialog.
public enum PrivacyGrant: String, Sendable, CaseIterable {
    case inputMonitoring = "input-monitoring"

    /// Raises macOS's dialog for this grant, when macOS still shows one.
    public func ask() async {
        switch self {
        case .inputMonitoring: _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
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
