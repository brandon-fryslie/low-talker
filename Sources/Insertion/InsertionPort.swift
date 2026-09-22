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
/// app's next request finds nothing listening.
public final class InsertionPort {
    private let port: CFMessagePort
    private let source: CFRunLoopSource
    /// The closure, retained for the C callback that has no captures of its own. This
    /// object is the one pair of hands the pointer passes through.
    /// [LAW:no-shared-mutable-globals]
    private let held: Unmanaged<Answering>

    /// No port could be opened under this name, which on a message port means another
    /// process already answers there - a second copy of this input method, running.
    public struct NameIsTaken: Error, CustomStringConvertible {
        public let name: String
        public var description: String {
            "no port could be hosted on \(name); another process is already answering there"
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
        self.port = port
        self.held = held
        source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        CFMessagePortInvalidate(port)
        held.release()
    }

    /// Whether `other` is this same port under the skin.
    ///
    /// Only a test asks. It exists because the answer is surprising and the design rests
    /// on it: `CFMessagePortCreateLocal` refuses a taken name only across processes, and
    /// within one it is get-or-create - so two of these in one process are one door with
    /// two owners, and the first to be released closes it for both.
    func hosts(_ other: InsertionPort) -> Bool { port === other.port }

    /// The closure, as something with an address the C callback can be handed.
    private final class Answering {
        let answer: (String) -> InsertionAnswer
        init(answer: @escaping (String) -> InsertionAnswer) { self.answer = answer }
    }
}
