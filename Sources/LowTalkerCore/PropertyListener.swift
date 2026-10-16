import CoreAudio
import CoreAudioCalls
import Dispatch

/// Calls `onChange` on the main actor each time the property at `address` on `object`
/// changes. The returned removal answers CoreAudio's status. Once it returns, CoreAudio
/// calls the listener no more, but a change it delivered before then can still reach
/// `onChange` after.
///
/// CoreAudio removes a listener only when handed the block it was added with, and answers
/// `noErr` whether or not it matched one. So the one block is made here and handed to both
/// calls, through `CoreAudioCalls`, because Swift's own import of the two calls bridges a
/// fresh block at each and the removal matches nothing. Measured for low-audio-fr3: removed
/// that way, a listener went on firing at every later change of the device's rate.
///
/// A removal that matches waits out any call CoreAudio has under way to that listener, and
/// a device being torn down calls its listeners with `dispatch_sync` onto their queue. On
/// the main queue, that hung for good both a removal made on main and one made on a queue
/// main was waiting on, measured for low-audio-fr3 by destroying an aggregate device. So
/// CoreAudio calls every listener on `deliveries`, where the block only posts `onChange`
/// to the main queue, and a removal waits on nothing main does.
/// [LAW:single-enforcer] The one place this process adds or removes a CoreAudio listener.
nonisolated func listen(
    to address: AudioObjectPropertyAddress,
    on object: AudioObjectID,
    refused fault: (OSStatus) -> AudioHardwareError,
    _ onChange: @escaping @MainActor () -> Void
) throws -> @Sendable () -> OSStatus {
    // Sendable because a removal can run on the readying queue, where an input replaced
    // mid-readying is let go of.
    let block: @Sendable @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange() } }
    }
    // [LAW:types-are-the-program] exception: a block is an object pointer, and the C side
    // takes it as one so that Swift has nothing to bridge.
    var adding = address
    try AudioHardwareError.check(
        lt_audio_object_add_property_listener_block(object, &adding, deliveries, unsafeBitCast(block, to: UnsafeRawPointer.self)),
        fault
    )
    return {
        var removing = address
        return lt_audio_object_remove_property_listener_block(object, &removing, deliveries, unsafeBitCast(block, to: UnsafeRawPointer.self))
    }
}

/// One serial queue for every listener, so changes reach the main queue in the order
/// CoreAudio delivered them.
private let deliveries = DispatchQueue(label: "ai.promptctl.low-talker.property-listeners")
