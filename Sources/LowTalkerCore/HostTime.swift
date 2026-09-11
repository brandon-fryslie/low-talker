import Foundation

/// A moment on the clock the machine has been up on, counted from when it came up.
/// The window server stamps every keyboard event on it and CoreAudio stamps every
/// microphone buffer on it, so how long before a sample a key went down is a
/// subtraction rather than a guess.
///
/// [LAW:one-source-of-truth] Each source hands out a bare integer in a unit of its
/// own choosing - the window server nanoseconds, CoreAudio the machine's raw ticks.
/// Each becomes one of these at the seam that parses it, so nothing downstream holds
/// a number whose clock and unit it has to remember.
public struct HostTime: Hashable, Sendable {
    public let uptime: Duration

    public init(uptime: Duration) {
        self.uptime = uptime
    }

    /// [LAW:effects-at-boundaries] The one reading of this clock; a moment that comes
    /// from an event carries its own and never wants this.
    public static var now: HostTime {
        HostTime(uptime: .nanoseconds(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
    }

    public static func - (moment: HostTime, earlier: HostTime) -> Duration {
        moment.uptime - earlier.uptime
    }

    public static func + (moment: HostTime, elapsed: Duration) -> HostTime {
        HostTime(uptime: moment.uptime + elapsed)
    }
}
