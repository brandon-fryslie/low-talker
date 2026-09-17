import Darwin
import Dispatch

/// The continuous clock's time, with a sleep that wakes when it was asked to.
///
/// A `ContinuousClock.sleep` on the main actor resumes one to two milliseconds late even
/// with no tolerance, which at 120 Hz is a large part of the interval. A thread blocked in `mach_wait_until` wakes on a timer
/// the kernel does not coalesce, so what is left late is the hop back to the caller's
/// actor, which is steady enough for `Player.lead` to cover with a short watch of the
/// clock. The shorter that watch, the less CPU a replay spends on it, and a replay exists
/// to measure something else's frames.
public struct WakingClock: Clock {
    public typealias Instant = ContinuousClock.Instant

    private static let waiter = DispatchQueue(label: "Typing.WakingClock", qos: .userInteractive)
    private static let timebase = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    public init() {}

    public var now: Instant { ContinuousClock.now }
    public var minimumResolution: Duration { ContinuousClock().minimumResolution }

    /// A deadline already past does not block the thread, since `mach_wait_until` returns
    /// for a time behind it, but the caller still pays the hop back to its actor.
    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let remaining = max(.zero, now.duration(to: deadline)).components
        let nanoseconds = UInt64(remaining.seconds) * 1_000_000_000 + UInt64(remaining.attoseconds / 1_000_000_000)
        let wake = mach_absolute_time() + nanoseconds * UInt64(Self.timebase.denom) / UInt64(Self.timebase.numer)
        await withCheckedContinuation { continuation in
            Self.waiter.async {
                mach_wait_until(wake)
                continuation.resume()
            }
        }
        try Task.checkCancellation()
    }
}
