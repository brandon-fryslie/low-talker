import Keystrokes

/// The keyboard as a client reaches it: the same two acts, with a root process in the
/// middle instead of the driver. A value over the connection, so a typist holds a
/// `KeyPress` and not a connection. [LAW:composability]
public struct HelperKeyboard: KeyPress, Sendable {
    let helper: HelperConnection

    public func down(_ usage: Usage) throws {
        try helper.call { service, reply in service.down(usage: usage.rawValue, reply: reply) }
    }

    public func releaseAll() throws {
        try helper.call { service, reply in service.releaseAll(reply: reply) }
    }
}
