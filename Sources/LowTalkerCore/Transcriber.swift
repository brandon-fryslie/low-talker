/// Turns a clip into a Transcript. The engine behind it is a config choice: WhisperKit
/// first, with Parakeet and Apple's SpeechAnalyzer behind the same seam.
///
/// [LAW:no-ambient-temporal-coupling] A Transcriber is ready the moment it exists.
/// Every engine loads its model in its initializer, so there is no unloaded
/// transcriber to call too early and no warm-up step a caller can forget. The app
/// holds "still loading" as its own state until the initializer returns; here, a
/// value in hand is the proof the model is resident.
public protocol Transcriber: Sendable {
    func transcribe(_ clip: AudioClip) async throws -> Transcript
}
