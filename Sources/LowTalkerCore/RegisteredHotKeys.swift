import Carbon.HIToolbox

/// The hotkey heard without watching the keyboard: each chord is registered with the
/// window server as a Carbon hot key, which needs no permission.
///
/// [LAW:composability] It sits behind the same seam as the event tap, so the detector
/// above it tells a hold from a tap exactly as it does for the tap. What the window server
/// reports is a chord going down and coming up, and this hands the detector the chord's
/// key moving under the chord's own modifiers - which is the event that completes it.
///
/// What it cannot do is why it is not the only tap. A hot key is a key plus modifiers, so a
/// bare modifier hold such as Right Option cannot be one, and Carbon's modifiers do not
/// know left from right, so `leftOption` is heard from either Option key. It never
/// swallows anything a chord did not claim and it never lapses: the window server delivers
/// hot keys to their owner and to nobody else, so there is no stream of other keys to
/// fall behind on.
public struct RegisteredHotKeys: KeyboardTap {
    /// The four-character code every registration from this process carries. The id beside
    /// it is the chord's index, which is how an event is traced back to its chord.
    private static let signature: OSType = 0x6C77_746B // 'lwtk'

    /// What the C callback reaches through its context pointer, and what disposal takes
    /// down: the handler and every hot key registered under it.
    @MainActor
    private final class Installed {
        let registrations: [Registration]
        let handle: @MainActor (KeyEvent) -> HotkeyDetector.Passage
        var handler: EventHandlerRef?
        var hotKeys: [EventHotKeyRef] = []

        init(registrations: [Registration], handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Passage) {
            self.registrations = registrations
            self.handle = handle
        }

        /// Unregisters, removes the handler, and gives back the retain the callback's
        /// context pointer held.
        func dispose() {
            hotKeys.forEach { UnregisterEventHotKey($0) }
            if let handler { RemoveEventHandler(handler) }
            Unmanaged.passUnretained(self).release()
        }

        @MainActor
        func deliver(_ event: EventRef) -> OSStatus {
            var id = EventHotKeyID()
            let read = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr else { return read }
            // Only this process's own registrations reach its handler, and each was given its
            // index as its id, so the index is in range by construction.
            let registration = registrations[Int(id.id)]
            let direction: KeyEvent.Direction = GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .down : .up
            // Carbon stamps an event in seconds on the clock the machine has been up on,
            // the one `HostTime` counts, so the press marks the audio where the key moved.
            let time = HostTime(uptime: .nanoseconds(Int64(GetEventTime(event) * 1_000_000_000)))
            // The passage is the event tap's question. A hot key reaches only its owner, so
            // there is nothing here to pass on or keep back.
            _ = handle(KeyEvent(key: .key(registration.key), direction: direction, modifiers: registration.chord.modifiers, time: time))
            return noErr
        }
    }

    public init() {}

    /// `onLapse` is never called. The system hands this handler the one chord it
    /// registered and nothing else, so it is not in front of the session's keyboard and
    /// there is no tap for the system to switch off.
    public func install(
        listeningFor chords: Set<KeyChord>,
        handling handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Passage,
        onLapse: @escaping @MainActor (HostTime, LapseCause) -> LapseResponse
    ) throws -> Disposal {
        // [LAW:parse-dont-validate] Every chord is proven registrable before anything is
        // registered, so a set with one bad chord registers none of them. Sorted so the
        // indices, and so the error a bad set reports, are the same on every run.
        let registrations = try chords.sorted { $0.description < $1.description }.map(Registration.init)
        for (index, registration) in registrations.enumerated() {
            if let earlier = registrations[..<index].first(where: { $0.combination == registration.combination }) {
                throw RegisteredHotKeyError.indistinguishable(earlier.chord, registration.chord)
            }
        }

        let installed = Installed(registrations: registrations, handle: handle)
        let context = Unmanaged.passRetained(installed).toOpaque()
        let target = GetApplicationEventTarget()
        let kinds = [kEventHotKeyPressed, kEventHotKeyReleased].map { EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0)) }
        // The application target dispatches on the main thread's event loop, so the
        // callback runs on the main actor.
        let installedHandler = InstallEventHandler(target, { _, event, context in
            let installed = Unmanaged<Installed>.fromOpaque(context!).takeUnretainedValue()
            return MainActor.assumeIsolated { installed.deliver(event!) }
        }, kinds.count, kinds, context, &installed.handler)
        guard installedHandler == noErr, installed.handler != nil else {
            installed.dispose()
            throw RegisteredHotKeyError.handlerRefused(installedHandler)
        }

        for (index, registration) in registrations.enumerated() {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(registration.key.rawValue), registration.carbonModifiers,
                EventHotKeyID(signature: Self.signature, id: UInt32(index)), target, 0, &reference)
            guard status == noErr, let reference else {
                // [LAW:no-silent-failure] What did register is taken back, so a refusal
                // leaves no half-heard hotkey behind it.
                installed.dispose()
                throw RegisteredHotKeyError.refused(registration.chord, status)
            }
            installed.hotKeys.append(reference)
        }
        return { installed.dispose() }
    }
}

/// A chord as the window server registers it: the key, and the modifiers in Carbon's bits.
private struct Registration {
    let chord: KeyChord
    let key: Key
    let carbonModifiers: UInt32

    /// The pair Carbon matches on. Two chords with one combination are the same hot key to
    /// the window server, however they name their sides.
    var combination: [UInt32] { [UInt32(key.rawValue), carbonModifiers] }

    init(_ chord: KeyChord) throws(RegisteredHotKeyError) {
        guard let key = chord.key else { throw .needsAKey(chord) }
        var bits: UInt32 = 0
        for modifier in chord.modifiers {
            guard let bit = modifier.carbonMask else { throw .noCarbonModifier(chord, modifier) }
            bits |= bit
        }
        self.chord = chord
        self.key = key
        carbonModifiers = bits
    }
}

private extension Modifier {
    /// Carbon's bit for this modifier, which is the same bit for both sides. Function has
    /// none, so a chord holding it cannot be registered.
    var carbonMask: UInt32? {
        switch self {
        case .leftShift, .rightShift: UInt32(shiftKey)
        case .leftControl, .rightControl: UInt32(controlKey)
        case .leftOption, .rightOption: UInt32(optionKey)
        case .leftCommand, .rightCommand: UInt32(cmdKey)
        case .function: nil
        }
    }
}

/// Why a set of chords could not be registered as hot keys.
public enum RegisteredHotKeyError: Error, Equatable, CustomStringConvertible {
    case needsAKey(KeyChord)
    case noCarbonModifier(KeyChord, Modifier)
    case indistinguishable(KeyChord, KeyChord)
    case handlerRefused(OSStatus)
    case refused(KeyChord, OSStatus)

    public var description: String {
        switch self {
        case .needsAKey(let chord):
            "\(chord) is modifiers alone, and a registered hot key needs a key besides them"
        case .noCarbonModifier(let chord, let modifier):
            "\(chord) holds \(modifier), which a registered hot key cannot"
        case .indistinguishable(let first, let second):
            "\(first) and \(second) are one hot key to the window server, which does not tell left modifiers from right"
        case .handlerRefused(let status):
            "the window server refused a hot key handler: OSStatus \(status)"
        case .refused(let chord, let status) where status == eventHotKeyExistsErr:
            "\(chord) is already registered as a hot key by another app or another copy of this one"
        case .refused(let chord, let status):
            "the window server refused \(chord) as a hot key: OSStatus \(status)"
        }
    }
}
