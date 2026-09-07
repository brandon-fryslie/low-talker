import Foundation
import KeyboardService

/// Accepts a connection when the caller is who the requirement says and nobody else has
/// the keyboard, and refuses it otherwise, saying why.
final class Listener: NSObject, NSXPCListenerDelegate {
    private let keyboard: any ServedKeyboard
    private let callers: CallerIdentity
    private let holder = Holder()

    init(keyboard: any ServedKeyboard, callers: CallerIdentity) {
        self.keyboard = keyboard
        self.callers = callers
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            guard let token = connection.callerAuditToken else { throw CallerIdentity.Refused.noAuditToken }
            try callers.check(auditToken: token)
            try holder.claim(ObjectIdentifier(connection), by: connection.processIdentifier)
        } catch {
            log("refused a connection from pid \(connection.processIdentifier): \(error)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: KeyboardService.self)
        connection.exportedObject = keyboard
        // Both, and not one: an interrupted connection ends invalid, a closed one ends
        // interrupted, and a client killed mid-burst can take either path. The release is
        // idempotent, so running it twice costs a report and running it never costs the
        // operator a held key. The keyboard is free for the next client only once this
        // one's keys are up, which is why invalidation releases the holder last.
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { [keyboard, holder] in
            keyboard.releaseEverything(because: "a client went away")
            holder.release(id)
        }
        connection.interruptionHandler = { [keyboard] in keyboard.releaseEverything(because: "a client was interrupted") }
        connection.resume()
        log("accepted a connection from pid \(connection.processIdentifier)")
        return true
    }
}
