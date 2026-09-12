import CoreAudio

/// What macOS is showing the user about the microphone, read off the property it shows it
/// from.
///
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` is true while any process on this Mac has
/// the device running, and it is what the menu-bar indicator and the privacy report follow.
/// Read on the default input device, which is the device a press opens, so what it answers
/// about is the microphone this app takes and not a second one something else is using.
///
/// It is the one honest source for "was the microphone open", precisely because it is not
/// this process's own bookkeeping. `AudioCapture.state` says what capture believes; what
/// the epic promises is what the user's menu bar shows, and the two are a map and its
/// territory. [FRAMING:representation]
public enum MicrophoneIndicator: Sendable, Equatable, CustomStringConvertible {
    /// Some process has the default input device running, so macOS is telling the user
    /// that something is listening.
    case lit
    /// Nothing has it running, and the menu bar shows no microphone.
    case dark

    public var description: String {
        switch self {
        case .lit: "lit"
        case .dark: "dark"
        }
    }

    /// What the indicator shows right now.
    ///
    /// Throws rather than answering `dark` where there is no reading to take. A Mac with no
    /// input device cannot say whether a microphone is open, and answering `dark` there
    /// would leave this instrument most confident exactly where it can see least - which is
    /// the one way it could hand back a clean bill of health for a promise nothing had
    /// tested. [LAW:no-silent-failure]
    public static func read() throws -> MicrophoneIndicator {
        // [LAW:one-source-of-truth] The device is the one a press would open, and `HALInput`
        // is where "which device is that" is answered for the whole repo.
        let device = try HALInput.defaultInput()
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try AudioHardwareError.check(
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running),
            AudioHardwareError.runningStateUnreadable
        )
        // [LAW:parse-dont-validate] The one place CoreAudio's flag becomes the fact a person
        // can hold their own menu bar up against.
        return running == 0 ? .dark : .lit
    }
}
