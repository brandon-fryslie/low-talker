import Darwin
import Foundation
import DarwinCalls

/// Mach messages as this channel uses them: bytes out, and bytes back with the process the
/// kernel says sent them.
///
/// Raw Mach rather than `CFMessagePort`, which carries the same messages but hands its
/// callback the bytes alone. Who sent them rides in the audit trailer the kernel appends
/// when asked, and asking is only possible from `mach_msg` itself. XPC would carry it too,
/// but a process macOS launches from a bundle has no launchd job and so no Mach service
/// for XPC to receive on (measured on low-input-method-s71.31s).
///
/// A message is a header, a byte count and the bytes, padded to the four the kernel
/// aligns to. Rights are the header's alone: anything else a sender attaches is released
/// on arrival and never read. [LAW:single-enforcer] This file is the one place bytes
/// become a message or a message becomes bytes.
enum Mach {
    /// A message as it arrived.
    struct Received {
        let id: mach_msg_id_t
        /// The bytes, or nil when the message was not in this channel's shape.
        let payload: Data?
        /// The process that sent it, as the kernel names it. [LAW:parse-dont-validate]
        /// Read off the trailer and nowhere else, so no sender can say who it is.
        let sender: audit_token_t
        /// Where the answer goes, if the sender said. Owned by whoever holds this until
        /// `answer` moves it or `discardReply` releases it.
        let reply: mach_port_t
        let replyDisposition: mach_msg_type_name_t

        /// Sends `payload` back to the sender, consuming the reply right either way.
        ///
        /// A zero timeout, because whoever answers is the queue the input method's text
        /// clients live on, and a reply that cannot be delivered at once is not one to wait
        /// for there: a sender that asked with a send-once right, which is the only kind this
        /// channel's own sender makes, cannot be full.
        func answer(_ payload: Data) -> kern_return_t {
            let status = Mach.send(payload, id: id, to: reply, disposition: replyDisposition, replyTo: Mach.noPort, timeout: .zero)
            // A send refused outright leaves the right with this process, and a right held
            // here with no message behind it is a sender waiting until it gives up.
            if status != MACH_MSG_SUCCESS, !Mach.pseudoReceived(status) { discardReply() }
            return status
        }

        func discardReply() {
            if reply != Mach.noPort { mach_port_deallocate(mach_task_self_, reply) }
        }
    }

    /// No port, typed as a port: Swift imports `MACH_PORT_NULL` as a plain integer.
    static let noPort = mach_port_t(MACH_PORT_NULL)

    /// What taking a message off a port came to.
    enum Arrival {
        case received(Received)
        case failed(kern_return_t)
    }

    /// The id of a message the kernel sends in place of an answer, when the right the
    /// answer was to travel on was destroyed unanswered.
    static let answerAbandoned = mach_msg_id_t(MACH_NOTIFY_SEND_ONCE)

    private static let headerSize = MemoryLayout<mach_msg_header_t>.size
    private static let countSize = MemoryLayout<UInt32>.size
    private static let trailerSize = MemoryLayout<mach_msg_audit_trailer_t>.size

    /// Sends `payload` to `remote`, asking for the answer on `replyTo` when it names a port.
    /// `timeout` bounds the wait for room in the far end's queue; nil waits as long as it
    /// takes.
    ///
    /// The rights the message moves are gone when this returns, sent or not, except after a
    /// send the kernel refused outright - an invalid destination, say - which leaves them
    /// with the caller. A send that timed out or was interrupted is handed back whole, rights
    /// and all, and those are released here rather than left for a caller to forget.
    static func send(
        _ payload: Data, id: mach_msg_id_t, to remote: mach_port_t, disposition: mach_msg_type_name_t,
        replyTo local: mach_port_t, timeout: Duration?
    ) -> kern_return_t {
        let size = headerSize + countSize + ((payload.count + 3) & ~3)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<mach_msg_header_t>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let header = buffer.bindMemory(to: mach_msg_header_t.self, capacity: 1)
        header.pointee.msgh_bits = lt_msgh_bits(
            disposition, local == Mach.noPort ? 0 : mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND_ONCE))
        header.pointee.msgh_size = mach_msg_size_t(size)
        header.pointee.msgh_remote_port = remote
        header.pointee.msgh_local_port = local
        header.pointee.msgh_id = id
        (buffer + headerSize).storeBytes(of: UInt32(payload.count), as: UInt32.self)
        payload.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer + headerSize + countSize, count: payload.count))
        let options = MACH_SEND_MSG | (timeout == nil ? 0 : MACH_SEND_TIMEOUT)
        let status = mach_msg(header, options, mach_msg_size_t(size), 0, Mach.noPort, timeout.map(milliseconds) ?? 0, Mach.noPort)
        // A message handed back keeps its ports where they were sent, so the answer's right is
        // in the local field, which `mach_msg_destroy` never reads: it takes a received
        // message's local port to hold no right at all.
        if pseudoReceived(status) {
            mach_msg_destroy(header)
            if header.pointee.msgh_local_port != Mach.noPort { mach_port_deallocate(mach_task_self_, header.pointee.msgh_local_port) }
        }
        return status
    }

    /// Whether a failed send came back to the sender whole, rights included.
    static func pseudoReceived(_ status: kern_return_t) -> Bool {
        status == MACH_SEND_TIMED_OUT || status == MACH_SEND_INTERRUPTED
    }

    /// Takes the next message off `port`, waiting up to `timeout` for one to arrive.
    static func receive(on port: mach_port_t, timeout: Duration) -> Arrival {
        var capacity = 1024
        while true {
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: capacity + trailerSize, alignment: MemoryLayout<mach_msg_header_t>.alignment)
            defer { buffer.deallocate() }
            let header = buffer.bindMemory(to: mach_msg_header_t.self, capacity: 1)
            let options = MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_TIMEOUT | lt_receive_with_audit_trailer()
            let status = mach_msg(
                header, options, 0, mach_msg_size_t(capacity + trailerSize), port, milliseconds(timeout), Mach.noPort)
            // A message larger than the buffer stays queued and says how large it is, so the
            // buffer grows to it and the same message is taken again.
            if status == MACH_RCV_TOO_LARGE {
                capacity = Int(header.pointee.msgh_size)
                continue
            }
            guard status == MACH_MSG_SUCCESS else { return .failed(status) }
            let size = Int(header.pointee.msgh_size)
            let trailer = (buffer + size).load(as: mach_msg_audit_trailer_t.self)
            let complex = header.pointee.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0
            let received = Received(
                id: header.pointee.msgh_id,
                payload: complex ? nil : payload(of: buffer, size: size),
                sender: trailer.msgh_audit,
                reply: header.pointee.msgh_remote_port,
                replyDisposition: lt_msgh_bits_remote(header.pointee.msgh_bits)
            )
            // Everything else the message carried - a voucher, and whatever a complex
            // message attached - is released here, once, whatever the sender put in it. The
            // reply right is lifted out first: it belongs to `Received` now.
            header.pointee.msgh_remote_port = Mach.noPort
            mach_msg_destroy(header)
            return .received(received)
        }
    }

    /// The bytes a message carries, or nil when its count claims more than it holds.
    private static func payload(of buffer: UnsafeMutableRawPointer, size: Int) -> Data? {
        guard size >= headerSize + countSize else { return nil }
        let count = Int((buffer + headerSize).load(as: UInt32.self))
        guard count <= size - headerSize - countSize else { return nil }
        return Data(bytes: buffer + headerSize + countSize, count: count)
    }

    /// A Mach status in words, or its number when Mach has no words for it.
    static func describe(_ status: kern_return_t) -> String {
        mach_error_string(status).map { String(cString: $0) } ?? "Mach status \(status)"
    }

    /// Rounded up, so a wait shorter than a millisecond is a millisecond and never the zero
    /// that means not waiting at all.
    private static func milliseconds(_ duration: Duration) -> mach_msg_timeout_t {
        let (seconds, attoseconds) = duration.components
        let (whole, part) = attoseconds.quotientAndRemainder(dividingBy: 1_000_000_000_000_000)
        return mach_msg_timeout_t(clamping: seconds * 1000 + whole + (part > 0 ? 1 : 0))
    }
}

/// A receive right this process holds, released with the value. [LAW:types-are-the-program]
/// Every port this channel receives on is one of these, so no path leaves one behind.
final class ReceiveRight {
    let port: mach_port_t

    struct NotAllocated: Error {
        let status: kern_return_t
    }

    /// `sendable` also makes a send right, which is what publishing the port by name needs.
    init(sendable: Bool) throws(NotAllocated) {
        var port = mach_port_t()
        let allocated = mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
        guard allocated == KERN_SUCCESS else { throw NotAllocated(status: allocated) }
        if sendable {
            let inserted = mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
            guard inserted == KERN_SUCCESS else {
                mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
                throw NotAllocated(status: inserted)
            }
        }
        self.port = port
        self.sendRights = sendable ? 1 : 0
    }

    private let sendRights: mach_port_delta_t

    deinit {
        mach_port_destruct(mach_task_self_, port, -sendRights, 0)
    }
}

extension audit_token_t {
    /// The process's pid, for a log line and never for a decision: the token is what is
    /// checked. Its sixth word, as `audit_token_to_pid` reads it.
    var pid: pid_t { pid_t(bitPattern: val.5) }
}
