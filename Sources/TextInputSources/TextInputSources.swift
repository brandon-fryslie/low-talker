import Foundation

/// The one lock every call into Text Input Sources takes.
///
/// Text Input Sources aborts the process - not an error, `abort()` - when two threads are
/// inside it at once: measured, a readiness read of the input method on one thread and a
/// keyboard layout read on another took the test process down. [LAW:single-enforcer] So
/// every call this program makes takes this one lock, beneath any module that calls it.
///
/// This covers only this program's own calls. In a process that also drives AppKit, AppKit
/// calls the same API from the main thread, and Apple's rule there is that everyone does:
/// the app makes these calls on the main actor.
public enum TextInputSources {
    private static let lock = NSLock()

    public static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }
}
