import CoreAudio
import CoreAudioCalls

/// Calls `onChange` on the main actor each time the property at `address` on `object`
/// changes, until the returned removal runs. The removal answers CoreAudio's status.
///
/// CoreAudio removes a listener only when handed the block it was added with, and answers
/// `noErr` whether or not it matched one: removing a block twice, or one never added, says
/// the same. So the one block is made here and handed to both calls, through
/// `CoreAudioCalls`, because Swift's own import of the two calls bridges a fresh block at
/// each and the removal matches nothing. Measured for low-audio-fr3: removed that way, a
/// listener went on firing at every later change of the device's rate.
/// [LAW:single-enforcer] The one place this process adds or removes a CoreAudio listener.
nonisolated func listen(
    to address: AudioObjectPropertyAddress,
    on object: AudioObjectID,
    refused fault: (OSStatus) -> AudioHardwareError,
    _ onChange: @escaping @MainActor () -> Void
) throws -> @Sendable () -> OSStatus {
    // Sendable because a removal can run on the readying queue, where an input replaced
    // mid-readying is let go of. The block only ever runs on the main queue.
    let block: @Sendable @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
        MainActor.assumeIsolated { onChange() }
    }
    // [LAW:types-are-the-program] exception: a block is an object pointer, and the C side
    // takes it as one so that Swift has nothing to bridge.
    var adding = address
    try AudioHardwareError.check(
        lt_audio_object_add_property_listener_block(object, &adding, .main, unsafeBitCast(block, to: UnsafeRawPointer.self)),
        fault
    )
    return {
        var removing = address
        return lt_audio_object_remove_property_listener_block(object, &removing, .main, unsafeBitCast(block, to: UnsafeRawPointer.self))
    }
}
