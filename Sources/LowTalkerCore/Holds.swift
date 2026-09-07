/// Whether `condition` comes to hold within `window`, asked every `poll`: true the
/// moment it holds, false once the window has passed with it still not holding. The
/// last ask comes after the window closes, so a change on its final tick counts.
///
/// [LAW:effects-at-boundaries] The condition is the caller's and is asked on the
/// caller's actor; this owns only the asking and the clock.
///
/// [LAW:no-ambient-temporal-coupling] The clock is a parameter, not the ambient one.
/// Callers get `ContinuousClock` by default; a caller that needs the outcome to be a
/// fact rather than a race - a test, above all - hands in a clock it advances itself,
/// and the result stops depending on how fast the machine happened to schedule.
public func holds<C: Clock>(
    within window: C.Duration,
    askingEvery poll: C.Duration,
    on clock: C = ContinuousClock(),
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
