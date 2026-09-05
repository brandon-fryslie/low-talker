import AVFoundation

/// Whether this process may listen, as macOS decides it: granted, with the proof that
/// anything listening must hold, or withheld, with the one reason it is.
///
/// [LAW:types-are-the-program] Granted and withheld are two arms so that a refusal
/// carries only refusal reasons; "withheld because authorized" is not a value.
public enum MicrophoneAuthorization: Sendable, Equatable, CustomStringConvertible {
    case granted(MicrophoneGrant)
    case withheld(Withheld)

    /// Why the microphone is not available, in the terms the user can act on.
    public enum Withheld: Error, Sendable, Equatable, CustomStringConvertible {
        /// Never asked. `MicrophonePermission.request()` shows the system prompt.
        case notDetermined
        /// Refused at the prompt or switched off since; only System Settings changes it.
        case denied
        /// Forbidden by policy (MDM, parental controls); nobody at this Mac can grant it.
        case restricted

        public var description: String {
            switch self {
            case .notDetermined: "microphone access has not been requested yet"
            case .denied: "microphone access is denied; allow it under System Settings > Privacy & Security > Microphone"
            case .restricted: "microphone access is restricted by policy on this Mac"
            }
        }
    }

    /// The grant, or the reason there is none.
    public func grant() throws(Withheld) -> MicrophoneGrant {
        switch self {
        case .granted(let grant): grant
        case .withheld(let reason): throw reason
        }
    }

    public var description: String {
        switch self {
        case .granted: "microphone access is granted"
        case .withheld(let reason): reason.description
        }
    }
}

/// Proof that the user had granted microphone access when this was minted. Only
/// `MicrophonePermission` mints one, so a function that takes a grant cannot run
/// before the user has said yes.
///
/// [LAW:no-ambient-temporal-coupling] "Ask before you listen" is an ordering, and
/// the grant makes it one the compiler checks rather than one a caller remembers.
public struct MicrophoneGrant: Sendable, Equatable {
    fileprivate init() {}
}

/// The two things macOS lets a process do about microphone access.
///
/// [LAW:effects-at-boundaries] Both are effects against TCC, the system's privacy
/// database. They sit behind this seam so the parsing and the polling above them run
/// in tests against a status that a test controls.
public protocol MicrophoneAuthority: Sendable {
    func status() -> AVAuthorizationStatus
    /// Prompts only while the status is `.notDetermined`; afterwards macOS answers
    /// from the decision it remembers, without a prompt.
    func requestAccess() async -> Bool
}

public struct SystemMicrophoneAuthority: MicrophoneAuthority {
    public init() {}

    public func status() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// Microphone authorization as this process sees it: read it, ask for it, or follow it.
public struct MicrophonePermission: Sendable {
    private let authority: any MicrophoneAuthority

    public init(authority: any MicrophoneAuthority = SystemMicrophoneAuthority()) {
        self.authority = authority
    }

    /// Where things stand right now, without prompting.
    public var current: MicrophoneAuthorization {
        Self.parse(authority.status())
    }

    /// Asks the user, then reports their answer. A fresh install sees the system prompt
    /// once; every later call returns the remembered decision without a prompt, so
    /// asking on every launch is what makes the first launch ask.
    ///
    /// [LAW:dataflow-not-control-flow] No "only if undetermined" here: macOS already
    /// holds that rule, and the status read afterwards is what tells denied from
    /// restricted, which the request's Bool cannot.
    public func request() async -> MicrophoneAuthorization {
        _ = await authority.requestAccess()
        return current
    }

    /// The current authorization, then every change to it for as long as the stream is
    /// consumed. macOS posts no notification when the user changes their mind in
    /// System Settings, so the status is read every `interval` and yielded when it
    /// differs from the last one.
    ///
    /// [LAW:no-ambient-temporal-coupling] The interval is the consumer's to choose,
    /// and cancelling the consumer's loop is what ends the polling.
    public func changes(every interval: Duration = .seconds(1)) -> AsyncStream<MicrophoneAuthorization> {
        AsyncStream { continuation in
            let polling = Task {
                var last = current
                continuation.yield(last)
                // Sleep throws only on cancellation, which is the stream's one way to end.
                while (try? await Task.sleep(for: interval)) != nil {
                    let now = current
                    if now != last {
                        continuation.yield(now)
                        last = now
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in polling.cancel() }
        }
    }

    /// The one place a TCC answer becomes a domain value, and the one place a grant is
    /// minted.
    private static func parse(_ status: AVAuthorizationStatus) -> MicrophoneAuthorization {
        switch status {
        case .authorized: .granted(MicrophoneGrant())
        case .notDetermined: .withheld(.notDetermined)
        case .denied: .withheld(.denied)
        case .restricted: .withheld(.restricted)
        // [LAW:no-silent-failure] A status this build has no meaning for is not a
        // refusal to display; it is an SDK the code has not been updated for.
        @unknown default: preconditionFailure("AVAuthorizationStatus \(status.rawValue) is not one this build knows")
        }
    }
}
