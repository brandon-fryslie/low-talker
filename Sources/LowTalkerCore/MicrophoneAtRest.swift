/// What the microphone does while nobody is dictating.
///
/// This is the epic's trade, named and given an owner. A microphone held open at rest
/// costs the user a menu-bar indicator that is lit on a Mac nobody has spoken to and a
/// privacy report that says low-talker is listening; what it buys is the look-back, the
/// 0.3 s of already-captured audio a press reaches back over so a key pressed mid-word
/// still holds that word. `shut` pays the look-back for the indicator and is what the app
/// runs on when no file says otherwise; `open` takes the trade the other way.
///
/// [LAW:types-are-the-program] A value rather than a flag, because "the microphone is
/// held at rest" is a fact about the device with two settled readings, and every place
/// that acts on it switches over this exhaustively. A third resting behaviour - a wake
/// word arming the microphone on its own terms, which is the reason the epic wanted this
/// seam before it wanted the wake word - arrives as a case here, and the compiler then
/// names every place that has to decide what it means.
///
/// [LAW:no-mode-explosion] It is not a flag anything in the app may set. The only writer
/// is the config file, so holding the microphone at rest is something the user asked for
/// in writing or it does not happen - which is what keeps it from creeping back in while
/// something unrelated is being fixed.
public enum MicrophoneAtRest: String, Hashable, Sendable, Decodable, CustomStringConvertible {
    /// Shut between presses. The microphone opens for a hold and closes when it ends, so
    /// the indicator is a record of use rather than of uptime, and a press has no
    /// look-back: the utterance starts where the microphone did.
    case shut
    /// Held from `AudioCapture.start` to `stop`, across presses. The indicator is lit for
    /// as long as the app runs, and the ring is continuous, so every press reaches back
    /// over real audio.
    case open

    /// How the app's status surface says which of the two it is in, written from the
    /// user's side of the trade: what their microphone is doing, not what the engine is.
    public var description: String {
        switch self {
        case .shut: "open only while you dictate"
        case .open: "held open the whole time low-talker is running"
        }
    }
}
