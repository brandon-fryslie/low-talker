/// Whether `condition` comes to hold within `window`, asked every `poll`: true the
/// moment it holds, false once the window has passed with it still not holding. The
/// last ask comes after the window closes, so a change on its final tick counts.
///
/// [LAW:effects-at-boundaries] The condition is the caller's and is asked on the
/// caller's actor; this owns only the asking and the clock.
public func holds(
    within window: Duration,
    askingEvery poll: Duration,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () throws -> Bool
) async throws -> Bool {
    try await holds(within: window, askingEvery: poll, on: ContinuousClock(), isolation: isolation, condition)
}

/// The same ask, against a clock the caller owns.
///
/// [LAW:no-ambient-temporal-coupling] A caller that needs the outcome to be a fact
/// rather than a race - a test, above all - hands in a clock it advances itself, and
/// the result stops depending on how fast the machine happened to schedule.
///
/// Two entry points rather than one `on:` with a default, because inferring `C` from a
/// default expression is rejected by the Swift 6.1 toolchain CI builds with.
public func holds<C: Clock>(
    within window: C.Duration,
    askingEvery poll: C.Duration,
    on clock: C,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () throws -> Bool
) async throws -> Bool {
    let deadline = clock.now.advanced(by: window)
    while try !condition() {
        guard clock.now < deadline else { return false }
        try await clock.sleep(until: clock.now.advanced(by: poll), tolerance: nil)
    }
    return true
}
