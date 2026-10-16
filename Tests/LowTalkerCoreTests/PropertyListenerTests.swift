import CoreAudio
import Foundation
@testable import LowTalkerCore
import Testing

@MainActor @Suite struct PropertyListenerTests {
    /// No status can show a removal happened, since one that matched nothing answers `noErr`
    /// too. So the test is a change a removed and a live listener could both hear, and only
    /// the live one does. The change is a private aggregate device made and destroyed, which
    /// moves the system's device list without touching any device the Mac uses: no
    /// microphone is needed, and nothing is left changed.
    ///
    /// Both listeners deliver on the main queue, in the order CoreAudio posts them. So by
    /// the time the live one has heard the second change, a removed one still registered
    /// would have heard the first.
    @Test(.timeLimit(.minutes(1))) func aRemovedListenerHearsNoLaterChange() async throws {
        let devices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var heardAfterRemoval = 0
        let remove = try listen(to: devices, on: system, refused: AudioHardwareError.deviceWatchFailed) { heardAfterRemoval += 1 }
        #expect(remove() == noErr)

        let (changes, change) = AsyncStream.makeStream(of: Void.self)
        let removeLive = try listen(to: devices, on: system, refused: AudioHardwareError.deviceWatchFailed) { change.yield() }
        defer { _ = removeLive() }

        let description = [
            kAudioAggregateDeviceUIDKey: "low-audio-fr3-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
        ] as CFDictionary
        var aggregate = AudioObjectID(0)
        try #require(AudioHardwareCreateAggregateDevice(description, &aggregate) == noErr)
        try #require(AudioHardwareDestroyAggregateDevice(aggregate) == noErr)
        for await _ in changes.prefix(2) {}
        #expect(heardAfterRemoval == 0)
    }
}
