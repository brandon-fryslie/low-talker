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
    let deadline = ContinuousClock.now + window
    while try !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: poll)
    }
    return true
}
