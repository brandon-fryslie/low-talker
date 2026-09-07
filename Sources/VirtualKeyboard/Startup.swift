/// What bringing one device up cost: the daemon's answer to the initialize request, and
/// its word that the device is ready.
///
/// Top level rather than the keyboard's, because the pointing device pays the same two
/// waits for the same reasons and reports them under the same names.
/// [LAW:one-type-per-behavior]
public struct Startup: Sendable, Equatable {
    /// How long the daemon took to answer the initialize request.
    public let answered: Duration
    /// How long until it said the device was ready.
    public let ready: Duration

    public init(answered: Duration, ready: Duration) {
        self.answered = answered
        self.ready = ready
    }
}
