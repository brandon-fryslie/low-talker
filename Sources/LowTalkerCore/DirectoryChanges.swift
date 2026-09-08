import CoreServices
import Foundation

/// A tick every time anything changes at or under a directory.
///
/// [LAW:decomposition] It knows nothing of what lives there. It does not report *what*
/// changed either, and that is the point rather than an omission: the one thing that
/// cares re-reads its own file and compares, which is the only way to learn what a
/// change meant, so a path here would be a fact its caller could not use. Reporting a
/// batch of changes as one tick is what keeps a busy directory cheap - the cost of
/// somebody else's churn is one tick, not one per file they touched.
enum DirectoryChanges {
    /// A tick for each batch of changes at or under `directory`, until the consuming
    /// task stops.
    ///
    /// - Parameter directory: must exist now. FSEvents delivers nothing at all for a
    ///   root that did not exist when the stream started - not the root's own creation,
    ///   and nothing under it afterwards either - so a caller with a path that may not
    ///   be there wants `nearestExistingDirectory(above:)`.
    ///
    /// A root deleted *while* it is watched is a different matter and needs no handling
    /// here: FSEvents reports the root changing and goes on delivering once it comes
    /// back. Both of those are measured behaviours, not read ones.
    ///
    /// Only the newest tick is kept for a consumer that is busy. Ticks carry nothing and
    /// say the same thing, so a queue of them would say it several times and cost a
    /// re-read for each. [LAW:dataflow-not-control-flow]
    static func ticks(under directory: URL) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let sink = Unmanaged.passRetained(Sink(continuation))
            var context = FSEventStreamContext(
                version: 0,
                info: sink.toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            guard let stream = FSEventStreamCreate(
                nil,
                { _, info, _, _, _, _ in
                    // `info` is the pointer set in `context` just below and never
                    // cleared, so this reads back exactly what this function put there.
                    Unmanaged<Sink>.fromOpaque(info!).takeUnretainedValue().continuation.yield()
                },
                &context,
                [directory.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                UInt32(
                    // Per-file granularity, so a file edited in place is reported and
                    // not only the entries appearing and disappearing around it.
                    kFSEventStreamCreateFlagFileEvents
                        // The root's own going and coming back is reported rather than
                        // passed over in silence. Measured: a root replaced at the same
                        // path goes on being delivered from without this flag, so what it
                        // adds is being told about the root, not the stream outliving it.
                        | kFSEventStreamCreateFlagWatchRoot
                    // Deliberately not kFSEventStreamCreateFlagNoDefer: handing the first
                    // change of a batch over at once reads a save that unlinks before it
                    // writes in the gap between the two, and calls the file missing. The
                    // latency below is the one thing that decides when a reading is taken.
                )
            ) else {
                // [LAW:no-silent-failure] The same vouch as the start below, failing the
                // same way. Nothing here can produce nil - an empty or malformed path
                // list, or the allocation failing - and if one ever does, the crash names
                // the directory rather than being a bare unwrap somewhere in this file.
                preconditionFailure("FSEvents refused a stream for \(directory.path)")
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            // [LAW:no-silent-failure] A start that failed and was not looked at is a
            // watch that never fires and never says so, which is the one way this type
            // can be wrong without anybody finding out. It fails only when the stream has
            // no queue to run on, which is set on the line above.
            precondition(FSEventStreamStart(stream), "FSEvents refused to start on \(directory.path)")
            let teardown = Teardown(stream: stream, sink: sink, queue: queue)
            continuation.onTermination = { _ in teardown() }
        }
    }

    /// The deepest directory on the way to `url` that exists right now.
    ///
    /// A config directory nobody has created yet is a legitimate state, and a stream
    /// rooted at one is deaf for the life of the process. So the watch starts as far
    /// down as it can and leans on the stream being recursive to see the rest of the
    /// path arrive underneath it.
    ///
    /// [LAW:dataflow-not-control-flow] One walk every time, with no case for "the
    /// directory is missing": when the file's own directory is there, it is the first
    /// thing the walk finds.
    static func nearestExistingDirectory(above url: URL) -> URL {
        let ancestors = sequence(first: url.deletingLastPathComponent()) { ancestor in
            ancestor.path == "/" ? nil : ancestor.deletingLastPathComponent()
        }
        // The author vouches: the walk ends at "/", which is a directory.
        return ancestors.first(where: isDirectory)!
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Long enough to gather one editor's save - which lands as a temp file, a rename,
    /// and a touch - into a single tick, and short enough that a saved config is running
    /// before the hand leaves the keyboard.
    static let latency: CFTimeInterval = 0.1

    private static let queue = DispatchQueue(label: "com.lowtalker.directory-changes")
}

/// The one stable address a C callback can find Swift at.
///
/// [LAW:no-shared-mutable-globals] FSEvents takes a raw pointer and hands it back, so
/// something has to hold still for it. This is that thing and nothing else: one owner,
/// retained where the stream is made and released where it is torn down.
private final class Sink: Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}

/// Everything one watch has to hand back, in the one place that hands it back.
///
/// [LAW:no-ambient-temporal-coupling] Ending the watch is not left to deinitialization
/// order: the stream's own termination runs this, so the FSEvents stream and the
/// pointer it was given outlive the continuation by exactly nothing.
///
/// `@unchecked Sendable` for the FSEvents handle, which Core Services does not describe
/// to Swift. It is made on one thread and used again only here, and `FSEventStreamStop`
/// is documented as the way to end delivery from any thread.
private struct Teardown: @unchecked Sendable {
    let stream: FSEventStreamRef
    let sink: Unmanaged<Sink>
    let queue: DispatchQueue

    func callAsFunction() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // [LAW:no-ambient-temporal-coupling] The stop above ends delivery; this hop waits
        // out the delivery already under way. Stopping first is what closes the set of
        // callbacks that can still hold the sink, and the queue is serial, so every one
        // of them is ahead of this block and done with the pointer before it goes. Async
        // and not sync: this runs on whatever thread ended the stream, which can be this
        // queue, and a sync onto itself is a deadlock.
        queue.async { sink.release() }
    }
}
