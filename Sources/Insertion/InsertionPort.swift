import Flavors
import Foundation

/// The input method's end of the channel: the named port the app sends to.
///
/// [LAW:effects-at-boundaries] Hosting the port and decoding the bytes is all this does.
/// What to do with the text is the closure's, and the closure is where the text input
/// system lives - so the half that knows about macOS clients knows nothing about ports,
/// and this half knows nothing about clients.
///
/// The answer closure runs on the run loop this was hosted on, which is the run loop of
/// whatever thread called `init`. That is the whole of the concurrency story here: host it
/// where the thing it inserts into lives, and the two never race.
/// [LAW:no-ambient-temporal-coupling]
///
/// Held for the life of the process by whoever makes it. Released, the port closes and the
/// app's next request finds nothing listening - from whichever thread happens to hold it
/// last, because the run loop it came off is the one it remembers rather than whichever one
/// is asking. [LAW:types-are-the-program] What it does NOT promise is release while a
/// request is in flight: the callback reads the closure through a pointer this object owns,
/// and teardown racing a dispatch already under way is a race no run loop arbitrates. Both
/// holders settle that by construction rather than by care - the input method never releases
/// it at all, and the suite's `PortOnItsOwnThread` drops it on the hosting thread after
/// `CFRunLoopRun()` has returned, which is after any answer has.
public final class InsertionPort {
    private let port: CFMessagePort
    private let source: CFRunLoopSource
    /// The loop the source went onto, kept because `deinit` has to name the same one. Asked
    /// for again there it would be whichever loop released this object, and taking a source
    /// off the wrong loop takes it off none - silently, leaving it on a loop still
    /// servicing a port invalidated underneath it. [LAW:one-source-of-truth]
    private let loop: CFRunLoop
    /// The closure, retained for the C callback that has no captures of its own. This
    /// object is the one pair of hands the pointer passes through.
    /// [LAW:no-shared-mutable-globals]
    private let held: Unmanaged<Answering>

    /// Someone is already answering on this name: another copy of this input method in
    /// another process, or another `InsertionPort` in this one.
    public struct NameIsTaken: Error, CustomStringConvertible {
        public let name: String
        public var description: String {
            "no port could be hosted on \(name); something is already answering there"
        }
    }

    /// Hosts this flavor's insert port, answering each request with `answer`.
    public convenience init(flavor: Flavor, answer: @escaping (String) -> InsertionAnswer) throws {
        try self.init(portName: flavor.inputMethodPortName, answer: answer)
    }

    /// Under a name someone else chose, which is how a test hosts one without being an
    /// input method. [LAW:decomposition]
    init(portName: String, answer: @escaping (String) -> InsertionAnswer) throws {
        let held = Unmanaged.passRetained(Answering(answer: answer))
        var context = CFMessagePortContext(
            version: 0, info: held.toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: CFMessagePortCallBack = { _, _, data, info in
            let answering = Unmanaged<Answering>.fromOpaque(info!).takeUnretainedValue()
            // Bytes that are not text are answered, never dropped: a sender that hears
            // nothing waits out its timeout and learns nothing. [LAW:no-silent-failure]
            let text = data.map { $0 as Data }.flatMap(Wire.text(of:))
            let answer = text.map(answering.answer) ?? .refused(.requestWasNotText)
            return Unmanaged.passRetained(Wire.answer(answer) as CFData)
        }
        guard let port = CFMessagePortCreateLocal(nil, portName as CFString, callback, &context, nil) else {
            held.release()
            throw NameIsTaken(name: portName)
        }
        // Across processes a taken name comes back as nil, caught above. WITHIN one it does
        // not: `CFMessagePortCreateLocal` is get-or-create, and the port it hands back
        // carries the FIRST creator's callback context - measured 2026-09-22, the second
        // caller's closure is never invoked and its `answer` is dead code that reports
        // success. A door that opens onto nothing is the failure this file is written
        // against, so it is refused here rather than discovered by a caller whose inserts
        // vanish. [LAW:no-silent-failure]
        var carried = CFMessagePortContext()
        CFMessagePortGetContext(port, &carried)
        guard carried.info == held.toOpaque() else {
            held.release()
            throw NameIsTaken(name: portName)
        }
        self.port = port
        self.held = held
        source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
    }

    deinit {
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMessagePortInvalidate(port)
        held.release()
    }

    /// The closure, as something with an address the C callback can be handed.
    private final class Answering {
        let answer: (String) -> InsertionAnswer
        init(answer: @escaping (String) -> InsertionAnswer) { self.answer = answer }
    }
}
