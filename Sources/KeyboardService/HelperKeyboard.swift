import Foundation
import Keystrokes

/// The keyboard as a client reaches it: the same two acts, with a root process in the
/// middle instead of the driver.
///
/// [LAW:effects-at-boundaries] The XPC connection is the effect, and it is the whole of
/// what this type adds. Everything above it - which character, which keys, whether the
/// target app is still in front - is decided in the user's own process against types that
/// know nothing about privilege.
///
/// Synchronous on purpose. Each call waits for the helper's acknowledgement before the
/// next report goes out, because reports posted back to back are lost in the driver and a
/// lost key-up leaves a key held for macOS to repeat. The waiting is not a sleep: the
/// daemon answers every request, and the answer is what the pacing is built on.
public final class HelperKeyboard: KeyPress {
    private let connection: NSXPCConnection

    /// The helper's refusal, or the connection's, as one thing a caller can catch.
    public struct Unreachable: Error, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
    }

    /// Connects to the helper's Mach service. The connection is lazy - launchd starts the
    /// job on the first call, not here - so a helper that is not installed is discovered
    /// when a key is first pressed rather than at construction.
    public init() {
        connection = NSXPCConnection(machServiceName: Helper.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: KeyboardService.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    /// One round trip, with the reply turned back into a throw.
    ///
    /// [LAW:no-silent-failure] An XPC call can fail in two ways that look nothing alike -
    /// the helper refused, or the connection did - and a client that only reads the first
    /// types into a dead service forever. Both arrive here, and both throw.
    private func call(_ body: (KeyboardService, @escaping (Error?) -> Void) -> Void) throws {
        let answered = DispatchSemaphore(value: 0)
        var failure: Error?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            failure = Unreachable(reason: "the keyboard helper could not be reached: \(error.localizedDescription)")
            answered.signal()
        }
        guard let service = proxy as? KeyboardService else {
            throw Unreachable(reason: "the keyboard helper answered with something that is not a keyboard")
        }
        body(service) { error in
            if let error, failure == nil { failure = error }
            answered.signal()
        }
        answered.wait()
        if let failure { throw failure }
    }

    public func down(_ usage: Usage) throws {
        try call { service, reply in service.down(usage: usage.rawValue, reply: reply) }
    }

    public func releaseAll() throws {
        try call { service, reply in service.releaseAll(reply: reply) }
    }
}
